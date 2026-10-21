# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'
require 'time'
require 'uri'

module ActionMailboxGraph
  Token = Struct.new(:access_token, :expires_at, keyword_init: true)

  class TokenProvider
    SCOPE = 'https://graph.microsoft.com/.default'
    RESOURCE = 'https://graph.microsoft.com/'
    EXPIRY_SKEW = 300

    def initialize
      @mutex = Mutex.new
    end

    def token
      @mutex.synchronize do
        return @cached_token if @cached_token && Time.now.to_i < @expires_at - EXPIRY_SKEW

        access_token, expires_at = fetch_token
        raise AuthenticationError, 'token provider returned an empty token' if access_token.to_s.empty?

        @cached_token = access_token
        @expires_at = expires_at
      end
      @cached_token
    end

    private

    def fetch_token
      raise NotImplementedError
    end

    def parse_token(payload, token_key: 'access_token')
      data = JSON.parse(payload)
      [data.fetch(token_key), token_expiration(data)]
    rescue JSON::ParserError, KeyError, ArgumentError => e
      raise AuthenticationError, "could not obtain Graph access token (#{e.class})"
    end

    def token_expiration(data)
      expires = data['expires_on'] || data['expiresOn'] || (Time.now.to_i + data.fetch('expires_in', 3600).to_i)
      parse_expiration(expires)
    end

    def parse_expiration(expires)
      return expires.to_i if expires.to_s.match?(/\A\d+\z/)

      Time.parse(expires.to_s).to_i
    end
  end

  class CallableTokenProvider < TokenProvider
    def initialize(callable)
      super()
      @callable = callable
    end

    private

    def fetch_token
      value = @callable.call
      unless value.is_a?(Token) && value.access_token.is_a?(String) && value.expires_at.is_a?(Integer)
        raise AuthenticationError, 'callable token provider must return a Token with an integer expiry'
      end

      [value.access_token, value.expires_at]
    end
  end

  class StaticTokenProvider < CallableTokenProvider
    def initialize(token, expires_at: Time.now.to_i + 3600)
      super(-> { Token.new(access_token: token, expires_at: expires_at) })
    end
  end

  class ManagedIdentityTokenProvider < TokenProvider
    def initialize(client_id: nil, env: ENV)
      super()
      @client_id = client_id
      @env = env
    end

    private

    def fetch_token
      response = identity_response
      unless response.is_a?(Net::HTTPSuccess)
        raise AuthenticationError, "managed identity endpoint returned HTTP #{response.code}"
      end

      parse_token(response.body)
    rescue SocketError, SystemCallError, Timeout::Error, URI::InvalidURIError
      raise AuthenticationError, 'managed identity endpoint could not be reached'
    end

    def identity_response
      endpoint, headers = endpoint_and_headers
      uri = identity_uri(endpoint)
      request = Net::HTTP::Get.new(uri)
      headers.each { |name, value| request[name] = value }
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 10) do |http|
        http.request(request)
      end
    end

    def identity_uri(endpoint)
      uri = URI(endpoint)
      params = { 'resource' => RESOURCE, 'api-version' => '2019-08-01' }
      params['client_id'] = @client_id unless @client_id.to_s.empty?
      uri.query = URI.encode_www_form(params)
      uri
    end

    def endpoint_and_headers
      [@env.fetch('IDENTITY_ENDPOINT'), { 'X-IDENTITY-HEADER' => @env.fetch('IDENTITY_HEADER') }]
    rescue KeyError
      raise AuthenticationError, 'managed identity endpoint credentials are incomplete'
    end
  end

  class AzureCliTokenProvider < TokenProvider
    private

    def fetch_token
      output, _error, status = Open3.capture3('az', 'account', 'get-access-token', '--scope', SCOPE, '--output', 'json')
      raise AuthenticationError, 'Azure CLI token request failed' unless status.success?

      parse_token(output, token_key: 'accessToken')
    rescue Errno::ENOENT
      raise AuthenticationError, 'Azure CLI is not installed'
    end
  end
end
