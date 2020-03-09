module Spree
  module V2
    module Storefront
      ProductSerializer.class_eval do
        attribute :subscribable,   &:subscribable?
        has_many :subscription_frequencies
      end
    end
  end
end
