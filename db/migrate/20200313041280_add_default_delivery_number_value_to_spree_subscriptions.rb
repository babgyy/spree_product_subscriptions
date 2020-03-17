class AddDefaultDeliveryNumberValueToSpreeSubscriptions < ActiveRecord::Migration[5.2]
  def change
    change_column :spree_subscriptions, :delivery_number, :integer, :default => 1_000_000_000
  end
end
