Rails.application.routes.draw do
  namespace :v1, defaults: {format: :json} do
    resources :events, only: :create
    match "events", to: "events#method_not_allowed", via: :all
    resources :endpoints, only: %i[create index show] do
      post :disable, on: :member
    end
    match "endpoints", to: "endpoints#method_not_allowed", via: :all, defaults: {allowed_methods: "GET, HEAD, POST"}
    match "endpoints/:id/disable", to: "endpoints#method_not_allowed", via: :all, defaults: {allowed_methods: "POST"}
    match "endpoints/:id", to: "endpoints#method_not_allowed", via: :all, defaults: {allowed_methods: "GET, HEAD"}
  end
end
