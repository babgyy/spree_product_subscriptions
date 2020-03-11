Spree::User.class_eval do
  has_many :subscriptions, through: :orders
end
