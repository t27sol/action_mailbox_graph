# frozen_string_literal: true

module ActionMailboxGraph
  class Configuration
    attr_accessor :mailbox, :identity_client_id, :folder, :processed_folder,
                  :poll_batch_size, :token_provider, :state_store, :http_open_timeout,
                  :http_read_timeout, :http_write_timeout, :max_retries

    def initialize
      @folder = "Inbox"
      @poll_batch_size = 50
      @http_open_timeout = 5
      @http_read_timeout = 30
      @http_write_timeout = 30
      @max_retries = 3
    end

    def validate!
      raise ConfigurationError, "mailbox must be configured" if mailbox.to_s.empty?
      raise ConfigurationError, "poll_batch_size must be positive" unless poll_batch_size.to_i.positive?

      self
    end
  end
end
