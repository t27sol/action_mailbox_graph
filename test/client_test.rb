# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require_relative '../lib/action_mailbox_graph'

WebMock.disable_net_connect!

class ClientTest < Minitest::Test
  def setup
    configuration = ActionMailboxGraph::Configuration.new
    configuration.mailbox = 'shared@example.test'
    configuration.token_provider = ActionMailboxGraph::StaticTokenProvider.new('test-token')
    @client = ActionMailboxGraph::Client.new(configuration)
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
