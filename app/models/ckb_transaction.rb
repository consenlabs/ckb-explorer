class CkbTransaction < ApplicationRecord
  MAX_PAGINATES_PER = 100
  DEFAULT_PAGINATES_PER = 10
  paginates_per DEFAULT_PAGINATES_PER
  max_paginates_per MAX_PAGINATES_PER

  enum tx_status: { pending: 0, proposed: 1, committed: 2 }, _prefix: :ckb_transaction

  belongs_to :block
  has_many :account_books, dependent: :destroy
  has_many :addresses, through: :account_books
  has_many :cell_inputs, dependent: :delete_all
  has_many :cell_outputs, dependent: :delete_all
  has_many :inputs, class_name: "CellOutput", inverse_of: "consumed_by", foreign_key: "consumed_by_id"
  has_many :outputs, class_name: "CellOutput", inverse_of: "generated_by", foreign_key: "generated_by_id"
  has_many :dao_events

  attribute :tx_hash, :ckb_hash
  attribute :header_deps, :ckb_array_hash, hash_length: ENV["DEFAULT_HASH_LENGTH"]

  scope :recent, -> { order("block_timestamp desc nulls last, id desc") }
  scope :cellbase, -> { where(is_cellbase: true) }
  scope :normal, -> { where(is_cellbase: false) }
  scope :created_after, ->(block_timestamp) { where("block_timestamp >= ?", block_timestamp) }
  scope :created_before, ->(block_timestamp) { where("block_timestamp <= ?", block_timestamp) }

  after_commit :flush_cache
  before_destroy :recover_dead_cell

  def self.cached_find(query_key)
    Rails.cache.realize([name, query_key], race_condition_ttl: 3.seconds) do
      find_by(tx_hash: query_key)
    end
  end

  def address_ids
    attributes["address_ids"]
  end

  def flush_cache
    Rails.cache.delete([self.class.name, tx_hash])
  end

  def display_inputs(previews: false)
    if is_cellbase
      cellbase_display_inputs
    else
      normal_tx_display_inputs(previews)
    end
  end

  def display_outputs(previews: false)
    if is_cellbase
      cellbase_display_outputs
    else
      normal_tx_display_outputs(previews)
    end
  end

  def income(address)
    outputs.where(address: address).sum(:capacity) - inputs.where(address: address).sum(:capacity)
  end

  def dao_transaction?
    inputs.where(cell_type: %w(nervos_dao_deposit nervos_dao_withdrawing)).exists? || outputs.where(cell_type: %w(nervos_dao_deposit nervos_dao_withdrawing)).exists?
  end

  def tx_status
    "committed"
  end

  def cell_info
    nil
  end

  def tx_display_info
    Rails.cache.fetch("TxDisplayInfo/#{id}", skip_nil: true) do
      TxDisplayInfo.find_by(ckb_transaction_id: self.id)
    end
  end

  def display_inputs_info(previews: false)
    if tx_display_info.blank?
      enabled = Rails.cache.read("enable_generate_tx_display_info")
      if enabled
        TxDisplayInfoGeneratorWorker.perform_async([self.id])
      end
      return
    end

    if previews
      tx_display_info.inputs[0..9]
    else
      tx_display_info.inputs
    end
  end

  def display_outputs_info(previews: false)
    return if tx_display_info.blank?

    if previews
      tx_display_info.outputs[0..9]
    else
      tx_display_info.outputs
    end
  end

  private

  def normal_tx_display_outputs(previews)
    cell_outputs_for_display = previews ? outputs.order(:id).limit(10) : outputs.order(:id)
    cell_outputs_for_display.map do |output|
      consumed_tx_hash = output.live? ? nil : output.consumed_by.tx_hash
      display_output = { id: output.id, capacity: output.capacity, address_hash: output.address_hash, status: output.status, consumed_tx_hash: consumed_tx_hash, cell_type: output.cell_type }
      display_output.merge!(attributes_for_udt_cell(output)) if output.udt?

      CkbUtils.hash_value_to_s(display_output)
    end
  end

  def cellbase_display_outputs
    cell_outputs_for_display = outputs.order(:id)
    cellbase = Cellbase.new(block)
    cell_outputs_for_display.map do |output|
      consumed_tx_hash = output.live? ? nil : output.consumed_by.tx_hash
      CkbUtils.hash_value_to_s(id: output.id, capacity: output.capacity, address_hash: output.address_hash, target_block_number: cellbase.target_block_number, base_reward: cellbase.base_reward, commit_reward: cellbase.commit_reward, proposal_reward: cellbase.proposal_reward, secondary_reward: cellbase.secondary_reward, status: output.status, consumed_tx_hash: consumed_tx_hash)
    end
  end

  def normal_tx_display_inputs(previews)
    cell_inputs_for_display = previews ? cell_inputs.order(:id).limit(10) : cell_inputs.order(:id)
    cell_inputs_for_display.each_with_index.map do |cell_input, index|
      previous_cell_output = cell_input.previous_cell_output
      display_input = { id: previous_cell_output.id, from_cellbase: false, capacity: previous_cell_output.capacity, address_hash: previous_cell_output.address_hash, generated_tx_hash: previous_cell_output.generated_by.tx_hash, cell_index: previous_cell_output.cell_index, cell_type: previous_cell_output.cell_type }
      display_input.merge!(attributes_for_dao_input(previous_cell_output)) if previous_cell_output.nervos_dao_withdrawing?
      display_input.merge!(attributes_for_dao_input(cell_outputs[index], false)) if previous_cell_output.nervos_dao_deposit?
      display_input.merge!(attributes_for_udt_cell(previous_cell_output)) if previous_cell_output.udt?

      CkbUtils.hash_value_to_s(display_input)
    end
  end

  def attributes_for_udt_cell(udt_cell)
    { udt_info: CkbUtils.hash_value_to_s(udt_cell.udt_info) }
  end

  def attributes_for_dao_input(nervos_dao_withdrawing_cell, is_phase2 = true)
    nervos_dao_withdrawing_cell_generated_tx = nervos_dao_withdrawing_cell.generated_by
    nervos_dao_deposit_cell = nervos_dao_withdrawing_cell_generated_tx.cell_inputs.order(:id)[nervos_dao_withdrawing_cell.cell_index].previous_cell_output
    compensation_started_block = Block.select(:number, :timestamp).find(nervos_dao_deposit_cell.block.id)
    compensation_ended_block = Block.select(:number, :timestamp).find(nervos_dao_withdrawing_cell_generated_tx.block_id)
    interest = CkbUtils.dao_interest(nervos_dao_withdrawing_cell)
    attributes = { compensation_started_block_number: compensation_started_block.number, compensation_ended_block_number: compensation_ended_block.number, compensation_started_timestamp: compensation_started_block.timestamp, compensation_ended_timestamp: compensation_ended_block.timestamp, interest: interest }
    if is_phase2
      locked_until_block = Block.select(:number, :timestamp).find(block_id)
      attributes[:locked_until_block_number] = locked_until_block.number
      attributes[:locked_until_block_timestamp] = locked_until_block.timestamp
    end

    CkbUtils.hash_value_to_s(attributes)
  end

  def cellbase_display_inputs
    cellbase = Cellbase.new(block)
    [CkbUtils.hash_value_to_s(id: nil, from_cellbase: true, capacity: nil, address_hash: nil, target_block_number: cellbase.target_block_number, generated_tx_hash: tx_hash)]
  end

  def recover_dead_cell
    inputs.update_all(status: "live")
  end
end

# == Schema Information
#
# Table name: ckb_transactions
#
#  id                    :bigint           not null, primary key
#  tx_hash               :binary
#  deps                  :jsonb
#  block_id              :bigint
#  block_number          :decimal(30, )
#  block_timestamp       :decimal(30, )
#  transaction_fee       :decimal(30, )
#  version               :integer
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  is_cellbase           :boolean          default(FALSE)
#  witnesses             :jsonb
#  header_deps           :binary
#  cell_deps             :jsonb
#  live_cell_changes     :integer
#  capacity_involved     :decimal(30, )
#  contained_address_ids :bigint           default([]), is an Array
#  tags                  :string           default([]), is an Array
#  contained_udt_ids     :bigint           default([]), is an Array
#  dao_address_ids       :bigint           default([]), is an Array
#  udt_address_ids       :bigint           default([]), is an Array
#
# Indexes
#
#  index_ckb_transactions_on_block_id_and_block_timestamp  (block_id,block_timestamp)
#  index_ckb_transactions_on_block_timestamp_and_id        (block_timestamp DESC NULLS LAST,id DESC)
#  index_ckb_transactions_on_contained_address_ids         (contained_address_ids) USING gin
#  index_ckb_transactions_on_contained_udt_ids             (contained_udt_ids) USING gin
#  index_ckb_transactions_on_dao_address_ids               (dao_address_ids) USING gin
#  index_ckb_transactions_on_is_cellbase                   (is_cellbase)
#  index_ckb_transactions_on_tags                          (tags) USING gin
#  index_ckb_transactions_on_tx_hash_and_block_id          (tx_hash,block_id) UNIQUE
#  index_ckb_transactions_on_udt_address_ids               (udt_address_ids) USING gin
#
