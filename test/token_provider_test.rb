# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'webmock/minitest'
require_relative '../lib/action_mailbox_graph'

WebMock.disable_net_connect!

class TokenProviderTest < Minitest::Test
  def test_managed_identity_uses_identity_header_and_selected_client_id
    provider = ActionMailboxGraph::ManagedIdentityTokenProvider.new(
      client_id: 'selected-identity',
      env: { 'IDENTITY_ENDPOINT' => 'http://identity.test/token', 'IDENTITY_HEADER' => 'identity-header' }
    )
    request = stub_request(:get, 'http://identity.test/token')
              .with(query: { resource: 'https://graph.microsoft.com/', 'api-version' => '2019-08-01',
                             client_id: 'selected-identity' }, headers: { 'X-IDENTITY-HEADER' => 'identity-header' })
              .to_return(status: 200, body: JSON.generate(access_token: 'managed-token', expires_in: 3600))

    assert_equal 'managed-token', provider.token
    assert_requested request, times: 1
  end

  def test_managed_identity_rejects_legacy_environment_without_requesting_a_token
    provider = ActionMailboxGraph::ManagedIdentityTokenProvider.new(
      env: { 'MSI_ENDPOINT' => 'http://legacy-identity.test/token', 'MSI_SECRET' => 'legacy-secret' }
    )
    stub_request(:get, /legacy-identity\.test/)
      .to_return(status: 200, body: JSON.generate(access_token: 'legacy-token', expires_in: 3600))

    error = assert_raises(ActionMailboxGraph::AuthenticationError) { provider.token }

    refute_includes error.message, 'legacy-secret'
    assert_not_requested :any, /legacy-identity\.test/
  end

  def test_managed_identity_requires_both_endpoint_and_header_before_requesting_a_token
    [{}, { 'IDENTITY_ENDPOINT' => 'http://identity.test/token' }, { 'IDENTITY_HEADER' => 'identity-header' }].each do |env|
      provider = ActionMailboxGraph::ManagedIdentityTokenProvider.new(env: env)

      assert_raises(ActionMailboxGraph::AuthenticationError) { provider.token }
    end
    assert_not_requested :any, /identity\.test/
  end

  def test_managed_identity_epoch_string_authenticates_and_refreshes_under_rails
    provider = ActionMailboxGraph::ManagedIdentityTokenProvider.new(
      env: { 'IDENTITY_ENDPOINT' => 'http://identity.test/token', 'IDENTITY_HEADER' => 'identity-header' }
    )
    request = stub_request(:get, 'http://identity.test/token')
              .with(query: { resource: 'https://graph.microsoft.com/', 'api-version' => '2019-08-01' },
                    headers: { 'X-IDENTITY-HEADER' => 'identity-header' })
              .to_return(status: 200, body: JSON.generate(access_token: 'managed-token', expires_on: '1792558800'))

    Time.stub(:now, Time.at(1792555200)) { 2.times { assert_equal 'managed-token', provider.token } }
    assert_requested request, times: 1
    Time.stub(:now, Time.at(1792558500)) { assert_equal 'managed-token', provider.token }
    assert_requested request, times: 2
  end

  def test_azure_cli_reads_access_token_and_prefers_utc_epoch_expiry
    output = JSON.generate(accessToken: 'cli-token', tokenType: 'Bearer', expires_on: 1792558800,
                           expiresOn: '2000-01-01 00:00:00.000000', tenant: 'tenant-id', subscription: 'subscription-id')
    calls = []
    capture = lambda do |*args|
      calls << args
      [output, '', successful_status]
    end
    provider = ActionMailboxGraph::AzureCliTokenProvider.new

    Open3.stub(:capture3, capture) do
      Time.stub(:now, Time.at(1792555200)) { 2.times { assert_equal 'cli-token', provider.token } }
      assert_equal 1, calls.length
      Time.stub(:now, Time.at(1792558500)) { assert_equal 'cli-token', provider.token }
    end
    assert_equal 2, calls.length
    assert_equal ['az', 'account', 'get-access-token', '--scope', 'https://graph.microsoft.com/.default',
                  '--output', 'json'], calls.first
  end

  def test_azure_cli_accepts_calendar_expires_on_from_older_cli
    output = JSON.generate(accessToken: 'legacy-cli-token', tokenType: 'Bearer',
                           expiresOn: '2099-01-02 03:04:05.000000', tenant: 'tenant-id')
    calls = 0
    capture = ->(*) { calls += 1; [output, '', successful_status] }
    provider = ActionMailboxGraph::AzureCliTokenProvider.new

    Open3.stub(:capture3, capture) do
      Time.stub(:now, Time.local(2099, 1, 2, 2, 4, 5)) do
        2.times { assert_equal 'legacy-cli-token', provider.token }
      end
      assert_equal 1, calls
      Time.stub(:now, Time.local(2099, 1, 2, 2, 59, 5)) { assert_equal 'legacy-cli-token', provider.token }
    end
    assert_equal 2, calls
  end

  def test_callable_token_objects_are_cached_and_refreshed_at_their_declared_expiry
    calls = 0
    callable = lambda do
      calls += 1
      ActionMailboxGraph::Token.new(access_token: "token-#{calls}", expires_at: 1792558800)
    end
    provider = ActionMailboxGraph::CallableTokenProvider.new(callable)

    Time.stub(:now, Time.at(1792555200)) { 2.times { assert_equal 'token-1', provider.token } }
    Time.stub(:now, Time.at(1792558500)) { assert_equal 'token-2', provider.token }
    assert_equal 2, calls
  end

  def test_callable_rejects_strings_hashes_and_alternate_expiry_forms
    invalid = ['secret-token', { access_token: 'secret-token', expires_at: 1792558800 },
               { 'access_token' => 'secret-token', 'expires_on' => 1792558800 },
               ActionMailboxGraph::Token.new(access_token: 'secret-token', expires_at: '1792558800'),
               ActionMailboxGraph::Token.new(access_token: 'secret-token', expires_at: Time.at(1792558800))]
    invalid.each do |value|
      provider = ActionMailboxGraph::CallableTokenProvider.new(-> { value })
      error = assert_raises(ActionMailboxGraph::AuthenticationError) { provider.token }
      refute_includes error.message, 'secret-token'
    end
  end

  def test_client_accepts_callable_token_object_and_static_provider
    configuration = ActionMailboxGraph::Configuration.new
    configuration.mailbox = 'shared@example.test'
    providers = [-> { ActionMailboxGraph::Token.new(access_token: 'test-token', expires_at: Time.now.to_i + 3600) },
                 ActionMailboxGraph::StaticTokenProvider.new('test-token')]
    request = stub_request(:post, 'https://graph.microsoft.com/v1.0/users/shared%40example.test/sendMail')
              .with(headers: { 'Authorization' => 'Bearer test-token' }).to_return(status: 202)

    providers.each do |provider|
      configuration.token_provider = provider
      ActionMailboxGraph::Client.new(configuration).send_mail('synthetic MIME')
    end
    assert_requested request, times: 2
  end

  private

  def successful_status
    Minitest::Mock.new.expect(:success?, true)
  end
end
