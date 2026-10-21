# frozen_string_literal: true

module ActionMailboxGraph
  module DeliveryInstrumentation
    def deliver_mail(mail)
      return yield if mail.delivery_method.is_a?(DeliveryMethod)

      super
    end
  end

  class DeliveryMethod
    def initialize(settings = {})
      @mailbox = settings[:mailbox]
      @client = settings[:client] || Client.new(ActionMailboxGraph.configuration)
    end

    def deliver!(mail)
      bcc = mail[:bcc]
      include_bcc = bcc&.include_in_headers
      bcc.include_in_headers = true if bcc
      @client.send_mail(mail.encoded, mailbox: @mailbox)
    ensure
      bcc.include_in_headers = include_bcc if bcc
    end
  end
end
