defmodule ConduitWeb.Router do
  use Phoenix.Router

  import ConduitWeb.Auth

  pipeline :api do
    plug :fetch_query_params
  end

  pipeline :auth_optional do
    plug :authenticate, :optional
  end

  pipeline :auth_required do
    plug :authenticate, :required
  end

  scope "/api", ConduitWeb do
    pipe_through :api

    post "/users", UserController, :register
    post "/users/login", UserController, :login
    get "/tags", TagController, :index

    scope "/" do
      pipe_through :auth_optional
      get "/profiles/:username", ProfileController, :show
      get "/articles", ArticleController, :index
    end

    scope "/" do
      pipe_through :auth_required
      get "/user", UserController, :show
      put "/user", UserController, :update
      post "/profiles/:username/follow", ProfileController, :follow
      delete "/profiles/:username/follow", ProfileController, :unfollow
      get "/articles/feed", ArticleController, :feed
      post "/articles", ArticleController, :create
      put "/articles/:slug", ArticleController, :update
      delete "/articles/:slug", ArticleController, :delete
      post "/articles/:slug/favorite", ArticleController, :favorite
      delete "/articles/:slug/favorite", ArticleController, :unfavorite
      post "/articles/:slug/comments", CommentController, :create
      delete "/articles/:slug/comments/:id", CommentController, :delete
    end

    # After /articles/feed so "feed" is not taken for a slug.
    scope "/" do
      pipe_through :auth_optional
      get "/articles/:slug", ArticleController, :show
      get "/articles/:slug/comments", CommentController, :index
    end
  end
end
