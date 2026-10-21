# frozen_string_literal: true

module ActionMailboxGraph
  class Poller
    def initialize(configuration = ActionMailboxGraph.configuration, client: nil, store: nil)
      @configuration = configuration.validate!
      @client = client || Client.new(configuration)
      @store = store || configuration.state_store || StateStore.new
    end

    def call
      mailbox = @configuration.mailbox
      folder = @configuration.folder
      delta_link = @store.delta_link(mailbox: mailbox, folder: folder)
      reset_used = false
      handed_off = 0

      loop do
        begin
          page = @client.delta_page(folder: folder, mailbox: mailbox, delta_link: delta_link)
        rescue RequestError => error
          raise unless error.status == 410 && !reset_used

          @store.clear_delta_link(mailbox: mailbox, folder: folder)
          delta_link = nil
          reset_used = true
          next
        end

        (page["value"] || []).each do |message|
          next if message["@removed"]

          message_id = message.fetch("id")
          unless @store.received?(mailbox: mailbox, message_id: message_id)
            mime = @client.raw_mime(message_id, mailbox: mailbox)
            inbound_email = ActionMailbox::InboundEmail.create_and_extract_message_id!(mime)
            @store.record_received(mailbox: mailbox, message_id: message_id, inbound_email_id: inbound_email&.id)
          end

          unless @store.processed?(mailbox: mailbox, message_id: message_id)
            if @configuration.processed_folder
              @client.move(message_id, folder: @configuration.processed_folder, mailbox: mailbox)
            else
              @client.mark_read(message_id, mailbox: mailbox)
            end
            @store.mark_processed(mailbox: mailbox, message_id: message_id)
            handed_off += 1
          end
        end

        next_link = page["@odata.nextLink"]
        if next_link
          delta_link = next_link
          next
        end

        final_link = page["@odata.deltaLink"]
        @store.save_delta_link(mailbox: mailbox, folder: folder, delta_link: final_link) if final_link
        break
      end
      handed_off
    end
  end
end
