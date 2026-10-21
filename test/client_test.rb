# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'stringio'
require_relative '../lib/action_mailbox_graph'

WebMock.disable_net_connect!

class ClientTest < Minitest::Test
  def setup
    configuration = ActionMailboxGraph::Configuration.new
    configuration.mailbox = 'shared@example.test'
    configuration.token_provider = ActionMailboxGraph::StaticTokenProvider.new('test-token')
    @configuration = configuration
    @client = ActionMailboxGraph::Client.new(configuration)
  end

  def test_graph_json_parse_errors_have_no_response_in_their_exception_chain
    link = 'https://graph.microsoft.com/v1.0/messages/delta?$deltatoken=opaque'
    stub_request(:get, link).to_return(status: 200, body: '{"value":[{"id":"private-response-marker"')
    stub_request(:get, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/id')
      .with(query: { '$select' => 'receivedDateTime' })
      .to_return(status: 200, body: '{"receivedDateTime":"private-response-marker"')

    [-> { @client.delta_page(delta_link: link) }, -> { @client.message_received_at('id') }].each do |operation|
      error = assert_raises(ActionMailboxGraph::RequestError, &operation)

      assert_equal 'Microsoft Graph returned an invalid JSON response', error.message
      assert_nil error.cause
      refute_includes error.full_message, 'private-response-marker'
    end
  end

  def test_message_received_at_fetches_the_timestamp_with_a_metadata_only_projection
    request = stub_request(:get, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/messages/id')
              .with(query: { '$select' => 'receivedDateTime' })
              .to_return(status: 200, body: JSON.generate(receivedDateTime: '2026-10-21T12:01:00Z'))

    assert_equal '2026-10-21T12:01:00Z', @client.message_received_at('id')
    assert_requested request, times: 1
  end

  def test_graph_http_parse_errors_have_no_response_in_their_exception_chain
    http = Object.new
    http.define_singleton_method(:request) do |_request|
      Net::HTTPResponse.read_new(StringIO.new("private-http-response-marker\r\n"))
    end
    client = ActionMailboxGraph::Client.new(@configuration, http_factory: ->(_uri) { http })
    operations = [-> { client.send_mail('synthetic MIME') }, -> { client.delta_page },
                  -> { client.raw_mime('id') }, -> { client.mark_read('id') },
                  -> { client.move('id', folder: 'processed') }, -> { client.message_received_at('id') }]

    operations.each do |operation|
      error = assert_raises(ActionMailboxGraph::RequestError, &operation)
      assert_equal 'Microsoft Graph returned an invalid HTTP response', error.message
      assert_nil error.cause
      refute_includes error.full_message, 'private-http-response-marker'
    end
  end

  def test_creation_only_delta_follows_absolute_next_and_saved_links_unchanged
    initial = 'https://graph.microsoft.com/v1.0/users/shared%40example.test/mailFolders/Inbox/messages/delta'
    next_link = 'https://graph.microsoft.com/v1.0/messages/delta?$skiptoken=opaque%2Bnext'
    delta_link = 'https://graph.microsoft.com/v1.0/messages/delta?$deltatoken=opaque%2Bsaved'
    initial_request = stub_request(:get, initial)
                      .with(query: { '$select' => 'id,isRead,receivedDateTime', '$top' => '50', 'changeType' => 'created' })
                      .to_return(status: 200, body: JSON.generate(value: [], '@odata.nextLink' => next_link))
    next_request = stub_request(:get, next_link)
                   .to_return(status: 200, body: JSON.generate(value: [], '@odata.deltaLink' => delta_link))
    saved_request = stub_request(:get, delta_link)
                    .to_return(status: 200, body: JSON.generate(value: [], '@odata.deltaLink' => delta_link))

    first_page = @client.delta_page
    last_page = @client.delta_page(delta_link: first_page.fetch('@odata.nextLink'))
    @client.delta_page(delta_link: last_page.fetch('@odata.deltaLink'))

    [initial_request, next_request, saved_request].each { |request| assert_requested request, times: 1 }
  end

  def test_delta_rejects_relative_links_before_making_any_http_request
    ['/messages/delta?$skiptoken=relative', 'messages/delta?$deltatoken=relative',
     '//graph.microsoft.com/v1.0/messages/delta', '?$deltatoken=relative'].each do |link|
      assert_raises(ActionMailboxGraph::ConfigurationError) { @client.delta_page(delta_link: link) }
    end

    assert_not_requested :any, /./
  end

  def test_delta_retains_https_origin_and_userinfo_validation
    ['http://graph.microsoft.com/v1.0/messages/delta', 'https://unrelated.test/messages/delta',
     'https://graph.microsoft.com.unrelated.test/messages/delta',
     'https://user:password@graph.microsoft.com/v1.0/messages/delta'].each do |link|
      assert_raises(ActionMailboxGraph::ConfigurationError) { @client.delta_page(delta_link: link) }
    end

    assert_not_requested :any, /./
  end
end
