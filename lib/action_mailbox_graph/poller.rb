# frozen_string_literal: true

require 'time'

module ActionMailboxGraph
  class Poller
    RESYNC_OVERLAP = 300

    def initialize(configuration = ActionMailboxGraph.configuration, client: nil, store: nil)
      @configuration = configuration.validate!
      @client = client || Client.new(configuration)
      @store = store || configuration.state_store || StateStore.new
    end

    def call
      mailbox = @configuration.mailbox
      folder = @configuration.folder
      cursor = { delta_link: @store.delta_link(mailbox: mailbox, folder: folder), reset: false,
                 handed_off: 0, started_at: Time.now }
      baseline_at = @store.baseline_at(mailbox: mailbox, folder: folder)
      cursor[:baseline] = cursor[:delta_link].nil? && baseline_at.nil?
      cursor[:received_since] = baseline_at || @store.start_baseline(
        mailbox: mailbox, folder: folder, started_at: cursor[:started_at]
      )

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
      cursor[:handed_off] += process_page(page, mailbox, cursor[:received_since]) unless cursor[:baseline]
      next_link = page['@odata.nextLink']
      return cursor[:delta_link] = next_link if next_link

      save_final_link(page, mailbox, folder, cursor[:started_at])
      false
    end

    def fetch_page(mailbox, folder, cursor)
      @client.delta_page(folder: folder, mailbox: mailbox, delta_link: cursor[:delta_link])
    rescue RequestError => e
      raise unless e.status == 410 && !cursor[:reset]

      last_polled_at = @store.last_polled_at(mailbox: mailbox, folder: folder)
      if last_polled_at
        cursor[:received_since] = [cursor[:received_since],
                                  last_polled_at - RESYNC_OVERLAP].max
      end
      cursor[:delta_link] = nil
      cursor[:reset] = true
      :restart
    end

    def process_page(page, mailbox, received_since)
      (page['value'] || []).sum do |message|
        next 0 if message['@removed']

        process_message(message, mailbox, received_since)
      end
    end

    def process_message(message, mailbox, received_since)
      message_id = message.fetch('id')
      return 0 if @store.processed?(mailbox: mailbox, message_id: message_id)

      unless @store.received?(mailbox: mailbox, message_id: message_id)
        return 0 if message_received_at(message, mailbox) < received_since

        mime = @client.raw_mime(message_id, mailbox: mailbox)
        mime = "X-Original-To: #{mailbox}\r\n#{mime}"
        inbound_email = ActionMailbox::InboundEmail.create_and_extract_message_id!(mime)
        @store.record_received(mailbox: mailbox, message_id: message_id, inbound_email_id: inbound_email&.id)
      end

      finalize_message(message_id, mailbox)
      @store.mark_processed(mailbox: mailbox, message_id: message_id)
      1
    end

    def message_received_at(message, mailbox)
      value = message['receivedDateTime'] || @client.message_received_at(message.fetch('id'), mailbox: mailbox)
      Time.iso8601(value)
    rescue ArgumentError, TypeError
      raise RequestError, 'Microsoft Graph returned an invalid received timestamp', cause: nil
    end

    def finalize_message(message_id, mailbox)
      if @configuration.processed_folder
        @client.move(message_id, folder: @configuration.processed_folder, mailbox: mailbox)
      else
        @client.mark_read(message_id, mailbox: mailbox)
      end
    end

    def save_final_link(page, mailbox, folder, started_at)
      final_link = page['@odata.deltaLink']
      return unless final_link

      @store.save_delta_link(mailbox: mailbox, folder: folder, delta_link: final_link, last_polled_at: started_at)
    end
  end
end
