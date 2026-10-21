# frozen_string_literal: true

module ActionMailboxGraph
  class DeliveryMethod
    def initialize(settings = {})
      @mailbox = settings[:mailbox]
      @client = settings[:client] || Client.new(ActionMailboxGraph.configuration)
    end

    def deliver!(mail)
      @client.send_mail(mail.encoded, mailbox: @mailbox)
    end
  end
end
