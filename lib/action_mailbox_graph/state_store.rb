# frozen_string_literal: true

module ActionMailboxGraph
  class StateStore
    def baseline_at(mailbox:, folder:)
      state_model.find_by(mailbox: mailbox, folder: folder)&.baseline_at
    end

    def start_baseline(mailbox:, folder:, started_at:)
      record = state_model.find_or_create_by!(mailbox: mailbox, folder: folder) do |state|
        state.baseline_at = started_at
      end
      record.baseline_at
    end

    def delta_link(mailbox:, folder:)
      state_model.find_by(mailbox: mailbox, folder: folder)&.delta_link
    end

    def last_polled_at(mailbox:, folder:)
      state_model.find_by(mailbox: mailbox, folder: folder)&.last_polled_at
    end

    def save_delta_link(mailbox:, folder:, delta_link:, last_polled_at:)
      record = state_model.find_by!(mailbox: mailbox, folder: folder)
      record.update!(delta_link: delta_link, last_polled_at: last_polled_at)
    end

    def received?(mailbox:, message_id:)
      receipt_model.exists?(mailbox: mailbox, graph_message_id: message_id)
    end

    def processed?(mailbox:, message_id:)
      receipt_model.exists?(mailbox: mailbox, graph_message_id: message_id, processed: true)
    end

    def record_received(mailbox:, message_id:, inbound_email_id:)
      receipt_model.create!(mailbox: mailbox, graph_message_id: message_id, inbound_email_id: inbound_email_id)
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def mark_processed(mailbox:, message_id:)
      receipt_model.find_by!(mailbox: mailbox, graph_message_id: message_id).update!(processed: true)
    end

    private

    def state_model
      ActionMailboxGraph::DeltaState
    end

    def receipt_model
      ActionMailboxGraph::Receipt
    end
  end

  class DeltaState < ActiveRecord::Base
    self.table_name = 'action_mailbox_graph_delta_states'
  end

  class Receipt < ActiveRecord::Base
    self.table_name = 'action_mailbox_graph_receipts'
  end
end
