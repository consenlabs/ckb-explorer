namespace :migration do
	desc "Usage: RAILS_ENV=production bundle exec rake migration:generate_tx_display_infos"
	task generate_tx_display_infos: :environment do
		threads = []
		CkbTransaction.where("id not in (?)", TxDisplayInfo.select(:ckb_transaction_id)).find_in_batches(batch_size: 200000).each do |txs|
			threads << Thread.new do
				value =
					txs.map do |tx|
						{ ckb_transaction_id: tx.id, inputs: tx.display_inputs, outputs: tx.display_outputs, created_at: Time.current, updated_at: Time.current }
					end
				if value.present?
					TxDisplayInfo.upsert_all(value)
					puts "done: #{value.size}"
				end
			end
		end
		threads.each(&:join)
	end
end