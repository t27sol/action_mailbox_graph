# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require_relative "../lib/action_mailbox_graph/errors"
require_relative "../lib/action_mailbox_graph/configuration"
require_relative "../lib/action_mailbox_graph/token_provider"
require_relative "../lib/action_mailbox_graph/client"
require_relative "../lib/action_mailbox_graph/poller"

WebMock.disable_net_connect!

module ActionMailbox
  class InboundEmail
    Record = Struct.new(:id)
    class << self
      attr_accessor :sources

      def create_and_extract_message_id!(source)
        self.sources ||= []
        sources << source
        Record.new(sources.length)
      end
    end
  end
end

class MemoryStore
  attr_reader :received_ids, :links

  def initialize
    @received_ids = []
    @links = {}
  end

  def delta_link(mailbox:, folder:)
    links[[mailbox, folder]]
  end

  def save_delta_link(mailbox:, folder:, delta_link:)
    links[[mailbox, folder]] = delta_link
  end

  def clear_delta_link(mailbox:, folder:)
    links[[mailbox, folder]] = nil
  end

  def received?(mailbox:, message_id:)
    received_ids.include?([mailbox, message_id])
  end

  def processed?(mailbox:, message_id:)
    @processed_ids ||= []
    @processed_ids.include?([mailbox, message_id])
  end

  def record_received(mailbox:, message_id:, inbound_email_id:)
    received_ids << [mailbox, message_id]
  end

  def mark_processed(mailbox:, message_id:)
    @processed_ids ||= []
    @processed_ids << [mailbox, message_id]
  end
end

class ActionMailboxGraphTest < Minitest::Test
  def setup
    ActionMailbox::InboundEmail.sources = []
    @configuration = ActionMailboxGraph::Configuration.new
    @configuration.mailbox = "shared@example.test"
    @configuration.token_provider = ActionMailboxGraph::StaticTokenProvider.new("synthetic-token")
  end

  def stub_json(method, url, status:, body:, headers: {})
    stub_request(method, url).to_return(status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" }.merge(headers))
  end

  def test_send_mime_uses_graph_mime_endpoint_and_base64_payload
    mime = "To: a@example.test\r\nSubject: synthetic\r\n\r\nbody"
    stub = stub_request(:post, "https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail")
      .with(headers: { "Content-Type" => "text/plain" }, body: Base64.strict_encode64(mime))
      .to_return(status: 202)

    ActionMailboxGraph::Client.new(@configuration).send_mime(mime)

    assert_requested(stub)
  end

  def test_poll_follows_delta_pages_hands_off_raw_mime_and_is_idempotent
    first = "https://graph.microsoft.com/v1.0/users/shared%40example.test/mailFolders/Inbox/messages/delta?%24select=id%2CisRead%2CreceivedDateTime&%24top=50"
    next_page = "https://graph.microsoft.com/v1.0/page/2"
    final_delta = "https://graph.microsoft.com/v1.0/delta/cursor"
    stub_json(:get, first, status: 200, body: { value: [{ id: "m1" }], "@odata.nextLink" => next_page })
    stub_json(:get, next_page, status: 200, body: { value: [{ id: "m2" }], "@odata.deltaLink" => final_delta })
    stub_json(:get, final_delta, status: 200, body: { value: [], "@odata.deltaLink" => final_delta })
    %w[m1 m2].each do |message_id|
      stub_request(:get, "https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/#{message_id}/$value")
        .to_return(status: 200, body: "Message-ID: <#{message_id}@example.test>\r\n\r\n#{message_id}")
      stub_request(:patch, "https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/#{message_id}")
        .to_return(status: 200, body: "{}")
    end
    store = MemoryStore.new
    poller = ActionMailboxGraph::Poller.new(@configuration, store: store)

    assert_equal 2, poller.call
    assert_equal 2, ActionMailbox::InboundEmail.sources.length
    assert_equal final_delta, store.delta_link(mailbox: @configuration.mailbox, folder: "Inbox")
    assert_equal 0, poller.call
    assert_equal 2, ActionMailbox::InboundEmail.sources.length
  end

  def test_expired_delta_link_is_cleared_and_restarted_once
    store = MemoryStore.new
    store.save_delta_link(mailbox: @configuration.mailbox, folder: "Inbox", delta_link: "https://graph.microsoft.com/stale")
    stub_request(:get, "https://graph.microsoft.com/stale").to_return(status: 410, body: "expired")
    initial = "https://graph.microsoft.com/v1.0/users/shared%40example.test/mailFolders/Inbox/messages/delta?%24select=id%2CisRead%2CreceivedDateTime&%24top=50"
    stub_json(:get, initial, status: 200, body: { value: [], "@odata.deltaLink" => "https://graph.microsoft.com/fresh" })

    assert_equal 0, ActionMailboxGraph::Poller.new(@configuration, store: store).call
    assert_equal "https://graph.microsoft.com/fresh", store.delta_link(mailbox: @configuration.mailbox, folder: "Inbox")
  end

  def test_retries_retryable_status_and_honors_retry_after
    delays = []
    stub = stub_request(:post, "https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail")
      .to_return({ status: 503, headers: { "Retry-After" => "2" }, body: "sensitive response" }, { status: 202 })
    client = ActionMailboxGraph::Client.new(@configuration, sleeper: ->(seconds) { delays << seconds })

    client.send_mime("synthetic MIME")

    assert_equal [2], delays
    assert_requested(stub, times: 2)
  end

  def test_errors_and_http_exchange_never_log_sensitive_data
    stub_request(:post, "https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail")
      .to_return(status: 400, body: "private recipient private body synthetic-token")

    output = capture_io do
      @error = assert_raises(ActionMailboxGraph::RequestError) do
        ActionMailboxGraph::Client.new(@configuration).send_mime("private body")
      end
    end
    refute_includes @error.message, "private"
    refute_includes @error.message, "synthetic-token"
    assert_equal ["", ""], output
  end
end
