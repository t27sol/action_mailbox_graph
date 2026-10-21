# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "uri"
require "time"
require "openssl"

module ActionMailboxGraph
  class Client
    GRAPH_ROOT = "https://graph.microsoft.com/v1.0"
    RETRYABLE = [429, 503, 504].freeze

    def initialize(configuration, http_factory: nil, sleeper: ->(seconds) { sleep(seconds) })
      @configuration = configuration.validate!
      provider = configuration.token_provider || ManagedIdentityTokenProvider.new(client_id: configuration.identity_client_id)
      @token_provider = provider.respond_to?(:token) ? provider : CallableTokenProvider.new(provider)
      @http_factory = http_factory
      @sleeper = sleeper
    end

    def send_mime(mime, mailbox: nil)
      address = selected_mailbox(mailbox)
      request(:post, user_path(address, "sendMail"), body: Base64.strict_encode64(mime), content_type: "text/plain")
      true
    end

    def delta_page(folder: @configuration.folder, mailbox: nil, delta_link: nil, url: nil)
      address = selected_mailbox(mailbox)
      response = request(:get, url || delta_link || user_path(address, "mailFolders/#{escape_path(folder)}/messages/delta"),
                         query: url || delta_link ? nil : { "$select" => "id,isRead,receivedDateTime", "$top" => @configuration.poll_batch_size })
      JSON.parse(response.body)
    end

    def raw_mime(message_id, mailbox: nil)
      request(:get, user_path(selected_mailbox(mailbox), "messages/#{escape_path(message_id)}/$value")).body
    end

    def mark_read(message_id, mailbox: nil)
      request(:patch, user_path(selected_mailbox(mailbox), "messages/#{escape_path(message_id)}"), body: { isRead: true }.to_json,
              content_type: "application/json")
    end

    def move(message_id, folder:, mailbox: nil)
      request(:post, user_path(selected_mailbox(mailbox), "messages/#{escape_path(message_id)}/move"),
              body: { destinationId: folder }.to_json, content_type: "application/json")
    end

    private

    def selected_mailbox(mailbox)
      return @configuration.mailbox if mailbox.nil?
      raise ConfigurationError, "mailbox override must be explicit and non-empty" if mailbox.to_s.empty?

      mailbox
    end

    def user_path(mailbox, suffix)
      "#{GRAPH_ROOT}/users/#{escape_path(mailbox)}/#{suffix}"
    end

    def escape_path(value)
      URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end

    def request(method, path, body: nil, content_type: nil, query: nil)
      uri = URI(path.start_with?("http") ? path : "#{GRAPH_ROOT}#{path}")
      unless uri.scheme == "https" && uri.host == "graph.microsoft.com" && uri.userinfo.nil?
        raise ConfigurationError, "Graph returned a delta URL outside the Microsoft Graph origin"
      end
      uri.query = URI.encode_www_form(query) if query
      retries = 0
      begin
        http_request(uri, method, body, content_type)
      rescue RequestError => error
        raise unless RETRYABLE.include?(error.status) && retries < @configuration.max_retries

        retries += 1
        @sleeper.call(retry_delay(error, retries))
        retry
      end
    end

    def http_request(uri, method, body, content_type)
      request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
      request = request_class.new(uri)
      request["Authorization"] = "Bearer #{@token_provider.token}"
      request["Accept"] = "application/json"
      request["Content-Type"] = content_type if content_type
      request.body = body if body
      response = http(uri).request(request)
      return response if response.is_a?(Net::HTTPSuccess)
      return response if method == :post && response.is_a?(Net::HTTPNoContent)

      retry_after = response["Retry-After"]
      raise RequestError.new("Microsoft Graph returned HTTP #{response.code}", status: response.code.to_i,
                             retry_after: retry_after)
    rescue AuthenticationError
      raise
    rescue RequestError
      raise
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise RequestError, "Microsoft Graph request failed due to a connection error"
    end

    def http(uri)
      return @http_factory.call(uri) if @http_factory

      Net::HTTP.new(uri.host, uri.port).tap do |client|
        client.use_ssl = uri.scheme == "https"
        client.open_timeout = @configuration.http_open_timeout
        client.read_timeout = @configuration.http_read_timeout
        client.write_timeout = @configuration.http_write_timeout if client.respond_to?(:write_timeout=)
      end
    end

    def retry_delay(error, attempt)
      raw = error.retry_after
      value = if raw&.match?(/\A\d+\z/)
        Integer(raw, 10)
      elsif raw
        [(Time.httpdate(raw) - Time.now).ceil, 0].max
      end
      value || [2**(attempt - 1), 30].min
    rescue ArgumentError, TypeError
      [2**(attempt - 1), 30].min
    end
  end
end
