# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'webmock/minitest'
require_relative '../lib/action_mailbox_graph'

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
  attr_reader :received_ids, :links, :receipt_ids

  def initialize
    @received_ids = []
    @links = {}
    @receipt_ids = []
    @poll_times = {}
    @baseline_times = {}
  end

  def start_baseline(mailbox:, folder:, started_at:)
    @baseline_times[[mailbox, folder]] ||= started_at
  end

  def baseline_at(mailbox:, folder:)
    @baseline_times[[mailbox, folder]]
  end

  def delta_link(mailbox:, folder:)
    links[[mailbox, folder]]
  end

  def last_polled_at(mailbox:, folder:)
    @poll_times[[mailbox, folder]]
  end

  def save_delta_link(mailbox:, folder:, delta_link:, last_polled_at:)
    links[[mailbox, folder]] = delta_link
    @poll_times[[mailbox, folder]] = last_polled_at
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
    receipt_ids << [mailbox, message_id, inbound_email_id]
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
    @configuration.mailbox = 'shared@example.test'
    @configuration.token_provider = ActionMailboxGraph::StaticTokenProvider.new('synthetic-token')
  end

  def stub_json(method, url, status:, body:, headers: {})
    stub_request(method, url).to_return(status: status, body: JSON.generate(body),
                                        headers: { 'Content-Type' => 'application/json' }.merge(headers))
  end

  def stub_delta_pages(first, next_page, final_delta)
    stub_json(:get, first, status: 200,
                           body: { value: [{ id: 'm1', receivedDateTime: '2026-10-21T12:01:00Z' }],
                                   '@odata.nextLink' => next_page })
    stub_json(:get, next_page, status: 200,
                               body: { value: [{ id: 'm2', receivedDateTime: '2026-10-21T12:02:00Z' }],
                                       '@odata.deltaLink' => final_delta })
    stub_json(:get, final_delta, status: 200, body: { value: [], '@odata.deltaLink' => final_delta })
    stub_message('m1')
    stub_message('m2')
  end

  def stub_message(message_id)
    base = "https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/#{message_id}"
    mime = "Message-ID: <#{message_id}@example.test>\r\n\r\n#{message_id}"
    stub_request(:get, "#{base}/$value").to_return(status: 200, body: mime)
    stub_request(:patch, base).to_return(status: 200, body: '{}')
  end

  def test_send_mime_uses_graph_mime_endpoint_and_base64_payload
    mime = "To: a@example.test\r\nSubject: synthetic\r\n\r\nbody"
    stub = stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
           .with(headers: { 'Content-Type' => 'text/plain' }, body: Base64.strict_encode64(mime))
           .to_return(status: 202)

    ActionMailboxGraph::Client.new(@configuration).send_mail(mime)

    assert_requested(stub)
  end

  def test_poll_follows_delta_pages_and_hands_off_raw_mime
    poller, store, final_delta = poller_with_two_page_fixture
    assert_equal 2, poller.call
    assert_equal 2, ActionMailbox::InboundEmail.sources.length
    assert_equal final_delta, store.delta_link(mailbox: @configuration.mailbox, folder: 'Inbox')
  end

  def test_poll_is_idempotent_after_restarting
    poller, = poller_with_two_page_fixture
    poller.call
    assert_equal 0, poller.call
    assert_equal 2, ActionMailbox::InboundEmail.sources.length
  end

  def test_sparse_events_skip_completed_receipts_and_resume_pending_finalization_without_metadata
    poller, store, final_delta = poller_with_two_page_fixture
    store.record_received(mailbox: @configuration.mailbox, message_id: 'm1', inbound_email_id: 1)
    store.mark_processed(mailbox: @configuration.mailbox, message_id: 'm1')
    store.record_received(mailbox: @configuration.mailbox, message_id: 'm2', inbound_email_id: 2)
    stub_json(:get, 'https://graph.microsoft.com/v1.0/saved/cursor',
              status: 200, body: { value: [{ id: 'm1', isRead: true }, { id: 'm2', isRead: false }],
                                   '@odata.deltaLink' => final_delta })

    assert_equal 1, poller.call
    assert_empty ActionMailbox::InboundEmail.sources
    assert store.processed?(mailbox: @configuration.mailbox, message_id: 'm2')
    assert_equal final_delta, store.delta_link(mailbox: @configuration.mailbox, folder: 'Inbox')
    assert_not_requested :get, %r{/users/shared%40example\.test/messages/}
    assert_not_requested :patch, %r{/messages/m1$}
    assert_requested :patch, %r{/messages/m2$}, times: 1
  end

  def test_unseen_sparse_events_resolve_timestamps_before_the_baseline_guard
    poller, store, final_delta = poller_with_two_page_fixture
    stub_json(:get, 'https://graph.microsoft.com/v1.0/saved/cursor',
              status: 200, body: { value: [{ id: 'old1', isRead: true }, { id: 'new1', isRead: false }],
                                   '@odata.deltaLink' => final_delta })
    stub_message_timestamp('old1', '2026-10-21T11:59:59Z')
    stub_message_timestamp('new1', '2026-10-21T12:01:00Z')
    stub_message('new1')

    assert_equal 1, poller.call
    assert_equal [[@configuration.mailbox, 'new1']], store.received_ids
    assert_equal 1, ActionMailbox::InboundEmail.sources.length
    assert_equal final_delta, store.delta_link(mailbox: @configuration.mailbox, folder: 'Inbox')
    assert_not_requested :get, %r{/messages/old1/\$value}
  end

  def test_first_poll_requests_created_changes_and_saves_baseline_without_importing_existing_messages
    first = initial_delta_url
    next_page = 'https://graph.microsoft.com/v1.0/baseline/page/2?$skiptoken=opaque-page'
    final_delta = 'https://graph.microsoft.com/v1.0/baseline/cursor?$deltatoken=opaque-cursor'
    stub_json(:get, first, status: 200, body: { value: [{ id: 'old1' }], '@odata.nextLink' => next_page })
    stub_json(:get, next_page, status: 200, body: { value: [{ id: 'old2' }], '@odata.deltaLink' => final_delta })
    stub_json(:get, final_delta, status: 200,
                                 body: { value: [{ id: 'new1', receivedDateTime: '2026-10-21T12:01:00Z' }],
                                         '@odata.deltaLink' => final_delta })
    stub_message('new1')
    store = MemoryStore.new
    poller = ActionMailboxGraph::Poller.new(@configuration, store: store)

    started_at = Time.utc(2026, 10, 21, 12)
    Time.stub(:now, started_at) { assert_equal 0, poller.call }
    assert_empty ActionMailbox::InboundEmail.sources
    assert_empty store.received_ids
    assert_equal final_delta, store.delta_link(mailbox: @configuration.mailbox, folder: 'Inbox')
    assert_equal started_at, store.last_polled_at(mailbox: @configuration.mailbox, folder: 'Inbox')
    assert_equal 1, poller.call
    assert_equal [[@configuration.mailbox, 'new1']], store.received_ids
  end

  def test_poll_preserves_mime_and_supplies_blind_delivery_recipient_for_rails_routing
    poller, = poller_with_two_page_fixture
    mime = "To: visible@example.test\r\nMessage-ID: <m1@example.test>\r\n\r\noriginal body"
    stub_request(:get, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/m1/$value')
      .to_return(status: 200, body: mime)

    poller.call

    source = ActionMailbox::InboundEmail.sources.first
    assert_equal "X-Original-To: shared@example.test\r\n#{mime}", source
    assert_includes Mail.read_from_string(source).recipients, 'shared@example.test'
    assert_includes Mail.read_from_string(source).recipients, 'visible@example.test'
  end

  def test_baseline_rejects_later_read_events_and_moves_but_allows_mail_at_and_after_first_start
    cursor = 'https://graph.microsoft.com/baseline/cursor'
    old_mail = { id: 'old1', receivedDateTime: '2026-10-21T11:59:59Z' }
    stub_json(:get, initial_delta_url, status: 200, body: { value: [old_mail], '@odata.deltaLink' => cursor })
    changes = [old_mail.merge(isRead: true), { id: 'moved1', receivedDateTime: '2026-10-21T11:00:00Z' },
               { id: 'new1', receivedDateTime: '2026-10-21T12:00:00Z' }, { id: 'deleted', '@removed' => {} }]
    later = [{ id: 'new2', receivedDateTime: '2026-10-21T12:01:00Z' }]
    stub_request(:get, cursor).to_return(
      { status: 200, body: JSON.generate(value: changes, '@odata.deltaLink' => cursor) },
      { status: 200, body: JSON.generate(value: later, '@odata.deltaLink' => cursor) }
    )
    stub_message('new1')
    stub_message('new2')
    store = MemoryStore.new
    poller = ActionMailboxGraph::Poller.new(@configuration, store: store)

    Time.stub(:now, Time.utc(2026, 10, 21, 12)) { assert_equal 0, poller.call }
    Time.stub(:now, Time.utc(2026, 10, 21, 12, 5)) { assert_equal 1, poller.call }
    Time.stub(:now, Time.utc(2026, 10, 21, 12, 10)) { assert_equal 1, poller.call }
    assert_equal [[@configuration.mailbox, 'new1'], [@configuration.mailbox, 'new2']], store.received_ids
    assert_equal 2, ActionMailbox::InboundEmail.sources.length
    assert_not_requested :get, %r{/messages/(old1|moved1)/\$value}
  end

  def test_failed_first_poll_recovers_intervening_mail_without_waiting_for_another_delta_event
    store = MemoryStore.new
    failure = stub_request(:get, initial_delta_url).to_return(status: 400)
    poller = ActionMailboxGraph::Poller.new(@configuration, store: store)
    Time.stub(:now, Time.utc(2026, 10, 21, 12)) do
      assert_raises(ActionMailboxGraph::RequestError) { poller.call }
    end
    remove_request_stub(failure)
    cursor = 'https://graph.microsoft.com/baseline/cursor'
    snapshot = [{ id: 'old1', receivedDateTime: '2026-10-21T11:59:59Z' },
                { id: 'new1', receivedDateTime: '2026-10-21T12:01:00Z' }]
    stub_json(:get, initial_delta_url, status: 200, body: { value: snapshot, '@odata.deltaLink' => cursor })
    stub_json(:get, cursor, status: 200, body: { value: [], '@odata.deltaLink' => cursor })
    stub_message('new1')

    Time.stub(:now, Time.utc(2026, 10, 21, 12, 5)) { assert_equal 1, poller.call }
    assert_equal 0, poller.call
    assert_equal [[@configuration.mailbox, 'new1']], store.received_ids
    assert_equal Time.utc(2026, 10, 21, 12), store.baseline_at(mailbox: @configuration.mailbox, folder: 'Inbox')
    assert_requested :get, %r{/messages/new1/\$value}, times: 1
  end

  def test_startup_recovery_handles_410_without_a_successful_poll_timestamp
    store = MemoryStore.new
    store.start_baseline(mailbox: @configuration.mailbox, folder: 'Inbox', started_at: Time.utc(2026, 10, 21, 12))
    final_delta = 'https://graph.microsoft.com/fresh'
    stub_request(:get, initial_delta_url).to_return(
      { status: 410 },
      { status: 200, body: JSON.generate(value: [{ id: 'new1', receivedDateTime: '2026-10-21T12:01:00Z' }],
                                         '@odata.deltaLink' => final_delta) }
    )
    stub_message('new1')

    assert_equal 1, ActionMailboxGraph::Poller.new(@configuration, store: store).call
    assert_equal [[@configuration.mailbox, 'new1']], store.received_ids
    assert_equal final_delta, store.delta_link(mailbox: @configuration.mailbox, folder: 'Inbox')
  end

  def test_resync_overlap_never_crosses_the_first_baseline_timestamp
    store = saved_poll_store(baseline_at: Time.utc(2026, 10, 21, 11, 58))
    stub_recovery_pages([{ id: 'old1', receivedDateTime: '2026-10-21T11:57:00Z' }],
                        [{ id: 'new1', receivedDateTime: '2026-10-21T11:58:00Z' }])
    stub_message('new1')

    assert_equal 1, ActionMailboxGraph::Poller.new(@configuration, store: store).call
    assert_equal [[@configuration.mailbox, 'new1']], store.received_ids
    assert_not_requested :get, %r{/messages/old1/\$value}
  end

  def test_expired_delta_resync_delivers_intervening_mail_once_with_overlap_and_receipts
    store = saved_poll_store
    store.record_received(mailbox: @configuration.mailbox, message_id: 'seen1', inbound_email_id: 1)
    store.mark_processed(mailbox: @configuration.mailbox, message_id: 'seen1')
    first_page = [{ id: 'old1', receivedDateTime: '2026-10-21T11:54:59Z' },
                  { id: 'seen1', isRead: true },
                  { id: 'overlap1', receivedDateTime: '2026-10-21T11:55:00Z' }]
    new_message = { id: 'new1', isRead: false }
    stub_recovery_pages(first_page, [new_message, new_message])
    stub_message_timestamp('new1', '2026-10-21T12:01:00Z')
    stub_message('overlap1')
    stub_message('new1')
    poller = ActionMailboxGraph::Poller.new(@configuration, store: store)

    started_at = Time.utc(2026, 10, 21, 12, 5)
    Time.stub(:now, started_at) { assert_equal 2, poller.call }
    assert_equal started_at, store.last_polled_at(mailbox: @configuration.mailbox, folder: 'Inbox')
    assert_equal 0, poller.call
    assert_equal 'https://graph.microsoft.com/fresh', store.delta_link(mailbox: @configuration.mailbox, folder: 'Inbox')
    assert_equal 2, ActionMailbox::InboundEmail.sources.length
    assert_equal 1, store.received_ids.count([@configuration.mailbox, 'new1'])
    assert_requested :get, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/new1/$value', times: 1
    refute_includes store.received_ids, [@configuration.mailbox, 'old1']
  end

  def test_failed_resync_preserves_checkpoint_and_retries_without_repeating_handoff
    store = saved_poll_store
    new_message = { id: 'new1', receivedDateTime: '2026-10-21T12:01:00Z' }
    stub_recovery_pages([new_message], [{ id: 'new2', receivedDateTime: '2026-10-21T12:02:00Z' }])
    stub_message('new1')
    stub_message('new2')
    failure = stub_request(:get, 'https://graph.microsoft.com/resync/page/2').to_return(status: 400)
    poller = ActionMailboxGraph::Poller.new(@configuration, store: store)

    assert_raises(ActionMailboxGraph::RequestError) { poller.call }
    assert_equal 'https://graph.microsoft.com/stale', store.delta_link(mailbox: @configuration.mailbox, folder: 'Inbox')
    assert_equal Time.utc(2026, 10, 21, 12), store.last_polled_at(mailbox: @configuration.mailbox, folder: 'Inbox')
    remove_request_stub(failure)
    assert_equal 1, poller.call
    assert_equal 2, ActionMailbox::InboundEmail.sources.length
    assert_requested :get, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/new1/$value', times: 1
  end

  def test_retries_retryable_status_and_honors_retry_after
    delays = []
    stub = stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
           .to_return({ status: 503, headers: { 'Retry-After' => '2' }, body: 'sensitive response' }, { status: 202 })
    client = ActionMailboxGraph::Client.new(@configuration, sleeper: ->(seconds) { delays << seconds })

    client.send_mail('synthetic MIME')

    assert_equal [2], delays
    assert_requested(stub, times: 2)
  end

  def test_errors_and_http_exchange_never_log_sensitive_data
    stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
      .to_return(status: 400, body: 'private recipient private body synthetic-token')

    output = capture_io do
      @error = assert_raises(ActionMailboxGraph::RequestError) do
        ActionMailboxGraph::Client.new(@configuration).send_mail('private body')
      end
    end
    refute_includes @error.message, 'private'
    refute_includes @error.message, 'synthetic-token'
    assert_equal ['', ''], output
  end

  def poller_with_two_page_fixture
    first = 'https://graph.microsoft.com/v1.0/saved/cursor'
    next_page = 'https://graph.microsoft.com/v1.0/page/2'
    final_delta = 'https://graph.microsoft.com/v1.0/delta/cursor'
    stub_delta_pages(first, next_page, final_delta)
    store = MemoryStore.new
    store.start_baseline(mailbox: @configuration.mailbox, folder: 'Inbox', started_at: Time.utc(2026, 10, 21, 12))
    store.save_delta_link(mailbox: @configuration.mailbox, folder: 'Inbox', delta_link: first, last_polled_at: Time.now)
    [ActionMailboxGraph::Poller.new(@configuration, store: store), store, final_delta]
  end

  def initial_delta_url
    'https://graph.microsoft.com/v1.0/users/shared%40example.test/mailFolders/Inbox/messages/delta?' \
      '%24select=id%2CisRead%2CreceivedDateTime&%24top=50&changeType=created'
  end

  def stub_message_timestamp(message_id, received_at)
    url = "https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/#{message_id}?%24select=receivedDateTime"
    stub_json(:get, url, status: 200, body: { receivedDateTime: received_at })
  end

  def saved_poll_store(baseline_at: Time.utc(2026, 10, 21, 11))
    MemoryStore.new.tap do |store|
      store.start_baseline(mailbox: @configuration.mailbox, folder: 'Inbox', started_at: baseline_at)
      store.save_delta_link(mailbox: @configuration.mailbox, folder: 'Inbox',
                            delta_link: 'https://graph.microsoft.com/stale', last_polled_at: Time.utc(2026, 10, 21, 12))
    end
  end

  def stub_recovery_pages(first_page, second_page)
    stub_request(:get, 'https://graph.microsoft.com/stale').to_return(status: 410, body: 'expired')
    stub_json(:get, initial_delta_url,
              status: 200, body: { value: first_page,
                                   '@odata.nextLink' => 'https://graph.microsoft.com/resync/page/2' })
    stub_json(:get, 'https://graph.microsoft.com/resync/page/2',
              status: 200, body: { value: second_page, '@odata.deltaLink' => 'https://graph.microsoft.com/fresh' })
    stub_json(:get, 'https://graph.microsoft.com/fresh',
              status: 200, body: { value: [], '@odata.deltaLink' => 'https://graph.microsoft.com/fresh' })
  end
end
