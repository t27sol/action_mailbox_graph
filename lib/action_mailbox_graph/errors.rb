# frozen_string_literal: true

module ActionMailboxGraph
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RequestError < Error
    attr_reader :status, :retry_after

    def initialize(message, status: nil, retry_after: nil)
      @status = status
      @retry_after = retry_after
      super(message)
    end
  end
  class ConfigurationError < Error; end
end
