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
      cursor = { delta_link: @store.delta_link(mailbox: mailbox, folder: folder), reset: false, handed_off: 0 }
      cursor[:baseline] = cursor[:delta_link].nil?

      poll_delta(mailbox, folder, cursor)
      cursor[:handed_off]
    end

    private

    def poll_delta(mailbox, folder, cursor)
      loop do
        page = fetch_page(mailbox, folder, cursor)
        next if page == :restart

        break unless advance_cursor(page, mailbox, folder, cursor)
      end
    end

    def advance_cursor(page, mailbox, folder, cursor)
      cursor[:handed_off] += process_page(page, mailbox) unless cursor[:baseline]
      next_link = page['@odata.nextLink']
      return cursor[:delta_link] = next_link if next_link

      save_final_link(page, mailbox, folder)
      false
    end

    def fetch_page(mailbox, folder, cursor)
      @client.delta_page(folder: folder, mailbox: mailbox, delta_link: cursor[:delta_link])
    rescue RequestError => e
      raise unless e.status == 410 && !cursor[:reset]

      @store.clear_delta_link(mailbox: mailbox, folder: folder)
      cursor[:delta_link] = nil
      cursor[:baseline] = true
      cursor[:reset] = true
      :restart
    end

    def process_page(page, mailbox)
      (page['value'] || []).sum do |message|
        message['@removed'] ? 0 : process_message(message, mailbox)
      end
    end

    def process_message(message, mailbox)
      message_id = message.fetch('id')
      unless @store.received?(mailbox: mailbox, message_id: message_id)
        mime = @client.raw_mime(message_id, mailbox: mailbox)
        mime = "X-Original-To: #{mailbox}\r\n#{mime}"
        inbound_email = ActionMailbox::InboundEmail.create_and_extract_message_id!(mime)
        @store.record_received(mailbox: mailbox, message_id: message_id, inbound_email_id: inbound_email&.id)
      end

      return 0 if @store.processed?(mailbox: mailbox, message_id: message_id)

      finalize_message(message_id, mailbox)
      @store.mark_processed(mailbox: mailbox, message_id: message_id)
      1
    end

    def finalize_message(message_id, mailbox)
      if @configuration.processed_folder
        @client.move(message_id, folder: @configuration.processed_folder, mailbox: mailbox)
      else
        @client.mark_read(message_id, mailbox: mailbox)
      end
    end

    def save_final_link(page, mailbox, folder)
      final_link = page['@odata.deltaLink']
      @store.save_delta_link(mailbox: mailbox, folder: folder, delta_link: final_link) if final_link
    end
  end
end
