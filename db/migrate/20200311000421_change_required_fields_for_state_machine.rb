class ChangeRequiredFieldsForStateMachine < ActiveRecord::Migration[5.2]
  def change
    remove_column :spree_subscriptions, :paused, :boolean
    remove_column :spree_subscriptions, :enabled, :boolean
    remove_column :spree_subscriptions, :next_occurrence_possible, :boolean
    rename_column :spree_subscriptions, :cancelled_at, :canceled_at
    add_column :spree_subscriptions, :state, :string
    add_column :spree_subscriptions, :activated_at, :datetime
    add_column :spree_subscriptions, :paused_at, :datetime
    add_column :spree_subscriptions, :active_duration_snapshot, :integer
  end
end
