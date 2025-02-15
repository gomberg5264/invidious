{% skip_file if flag?(:api_only) %}

module Invidious::Routes::Playlists
  def self.new(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env)

    return env.redirect "/" if user.nil?

    user = user.as(User)
    sid = sid.as(String)
    csrf_token = generate_response(sid, {":create_playlist"}, HMAC_KEY)

    templated "create_playlist"
  end

  def self.create(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env)

    return env.redirect "/" if user.nil?

    user = user.as(User)
    sid = sid.as(String)
    token = env.params.body["csrf_token"]?

    begin
      validate_request(token, sid, env.request, HMAC_KEY, locale)
    rescue ex
      return error_template(400, ex)
    end

    title = env.params.body["title"]?.try &.as(String)
    if !title || title.empty?
      return error_template(400, "Title cannot be empty.")
    end

    privacy = PlaylistPrivacy.parse?(env.params.body["privacy"]?.try &.as(String) || "")
    if !privacy
      return error_template(400, "Invalid privacy setting.")
    end

    if Invidious::Database::Playlists.count_owned_by(user.email) >= 100
      return error_template(400, "User cannot have more than 100 playlists.")
    end

    playlist = create_playlist(title, privacy, user)

    env.redirect "/playlist?list=#{playlist.id}"
  end

  def self.subscribe(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    referer = get_referer(env)

    return env.redirect "/" if user.nil?

    user = user.as(User)

    playlist_id = env.params.query["list"]
    playlist = get_playlist(playlist_id)
    subscribe_playlist(user, playlist)

    env.redirect "/playlist?list=#{playlist.id}"
  end

  def self.delete_page(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env)

    return env.redirect "/" if user.nil?

    user = user.as(User)
    sid = sid.as(String)

    plid = env.params.query["list"]?
    if !plid || plid.empty?
      return error_template(400, "A playlist ID is required")
    end

    playlist = Invidious::Database::Playlists.select(id: plid)
    if !playlist || playlist.author != user.email
      return env.redirect referer
    end

    csrf_token = generate_response(sid, {":delete_playlist"}, HMAC_KEY)

    templated "delete_playlist"
  end

  def self.delete(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env)

    return env.redirect "/" if user.nil?

    plid = env.params.query["list"]?
    return env.redirect referer if plid.nil?

    user = user.as(User)
    sid = sid.as(String)
    token = env.params.body["csrf_token"]?

    begin
      validate_request(token, sid, env.request, HMAC_KEY, locale)
    rescue ex
      return error_template(400, ex)
    end

    playlist = Invidious::Database::Playlists.select(id: plid)
    if !playlist || playlist.author != user.email
      return env.redirect referer
    end

    Invidious::Database::Playlists.delete(plid)

    env.redirect "/feed/playlists"
  end

  def self.edit(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env)

    return env.redirect "/" if user.nil?

    user = user.as(User)
    sid = sid.as(String)

    plid = env.params.query["list"]?
    if !plid || !plid.starts_with?("IV")
      return env.redirect referer
    end

    page = env.params.query["page"]?.try &.to_i?
    page ||= 1

    playlist = Invidious::Database::Playlists.select(id: plid)
    if !playlist || playlist.author != user.email
      return env.redirect referer
    end

    begin
      videos = get_playlist_videos(playlist, offset: (page - 1) * 100)
    rescue ex
      videos = [] of PlaylistVideo
    end

    csrf_token = generate_response(sid, {":edit_playlist"}, HMAC_KEY)

    templated "edit_playlist"
  end

  def self.update(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env)

    return env.redirect "/" if user.nil?

    plid = env.params.query["list"]?
    return env.redirect referer if plid.nil?

    user = user.as(User)
    sid = sid.as(String)
    token = env.params.body["csrf_token"]?

    begin
      validate_request(token, sid, env.request, HMAC_KEY, locale)
    rescue ex
      return error_template(400, ex)
    end

    playlist = Invidious::Database::Playlists.select(id: plid)
    if !playlist || playlist.author != user.email
      return env.redirect referer
    end

    title = env.params.body["title"]?.try &.delete("<>") || ""
    privacy = PlaylistPrivacy.parse(env.params.body["privacy"]? || "Public")
    description = env.params.body["description"]?.try &.delete("\r") || ""

    if title != playlist.title ||
       privacy != playlist.privacy ||
       description != playlist.description
      updated = Time.utc
    else
      updated = playlist.updated
    end

    Invidious::Database::Playlists.update(plid, title, privacy, description, updated)

    env.redirect "/playlist?list=#{plid}"
  end

  def self.add_playlist_items_page(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env)

    return env.redirect "/" if user.nil?

    user = user.as(User)
    sid = sid.as(String)

    plid = env.params.query["list"]?
    if !plid || !plid.starts_with?("IV")
      return env.redirect referer
    end

    page = env.params.query["page"]?.try &.to_i?
    page ||= 1

    playlist = Invidious::Database::Playlists.select(id: plid)
    if !playlist || playlist.author != user.email
      return env.redirect referer
    end

    query = env.params.query["q"]?
    if query
      begin
        search_query, items, operators = process_search_query(query, page, user, region: nil)
        videos = items.select(SearchVideo).map(&.as(SearchVideo))
      rescue ex
        videos = [] of SearchVideo
      end
    else
      videos = [] of SearchVideo
    end

    env.set "add_playlist_items", plid
    templated "add_playlist_items"
  end

  def self.playlist_ajax(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env, "/")

    redirect = env.params.query["redirect"]?
    redirect ||= "true"
    redirect = redirect == "true"

    if !user
      if redirect
        return env.redirect referer
      else
        return error_json(403, "No such user")
      end
    end

    user = user.as(User)
    sid = sid.as(String)
    token = env.params.body["csrf_token"]?

    begin
      validate_request(token, sid, env.request, HMAC_KEY, locale)
    rescue ex
      if redirect
        return error_template(400, ex)
      else
        return error_json(400, ex)
      end
    end

    if env.params.query["action_create_playlist"]?
      action = "action_create_playlist"
    elsif env.params.query["action_delete_playlist"]?
      action = "action_delete_playlist"
    elsif env.params.query["action_edit_playlist"]?
      action = "action_edit_playlist"
    elsif env.params.query["action_add_video"]?
      action = "action_add_video"
      video_id = env.params.query["video_id"]
    elsif env.params.query["action_remove_video"]?
      action = "action_remove_video"
    elsif env.params.query["action_move_video_before"]?
      action = "action_move_video_before"
    else
      return env.redirect referer
    end

    begin
      playlist_id = env.params.query["playlist_id"]
      playlist = get_playlist(playlist_id).as(InvidiousPlaylist)
      raise "Invalid user" if playlist.author != user.email
    rescue ex
      if redirect
        return error_template(400, ex)
      else
        return error_json(400, ex)
      end
    end

    if !user.password
      # TODO: Playlist stub, sync with YouTube for Google accounts
      # playlist_ajax(playlist_id, action, env.request.headers)
    end
    email = user.email

    case action
    when "action_edit_playlist"
      # TODO: Playlist stub
    when "action_add_video"
      if playlist.index.size >= 500
        if redirect
          return error_template(400, "Playlist cannot have more than 500 videos")
        else
          return error_json(400, "Playlist cannot have more than 500 videos")
        end
      end

      video_id = env.params.query["video_id"]

      begin
        video = get_video(video_id)
      rescue ex
        if redirect
          return error_template(500, ex)
        else
          return error_json(500, ex)
        end
      end

      playlist_video = PlaylistVideo.new({
        title:          video.title,
        id:             video.id,
        author:         video.author,
        ucid:           video.ucid,
        length_seconds: video.length_seconds,
        published:      video.published,
        plid:           playlist_id,
        live_now:       video.live_now,
        index:          Random::Secure.rand(0_i64..Int64::MAX),
      })

      Invidious::Database::PlaylistVideos.insert(playlist_video)
      Invidious::Database::Playlists.update_video_added(playlist_id, playlist_video.index)
    when "action_remove_video"
      index = env.params.query["set_video_id"]
      Invidious::Database::PlaylistVideos.delete(index)
      Invidious::Database::Playlists.update_video_removed(playlist_id, index)
    when "action_move_video_before"
      # TODO: Playlist stub
    else
      return error_json(400, "Unsupported action #{action}")
    end

    if redirect
      env.redirect referer
    else
      env.response.content_type = "application/json"
      "{}"
    end
  end

  def self.show(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get?("user").try &.as(User)
    referer = get_referer(env)

    plid = env.params.query["list"]?.try &.gsub(/[^a-zA-Z0-9_-]/, "")
    if !plid
      return env.redirect "/"
    end

    page = env.params.query["page"]?.try &.to_i?
    page ||= 1

    if plid.starts_with? "RD"
      return env.redirect "/mix?list=#{plid}"
    end

    begin
      playlist = get_playlist(plid)
    rescue ex
      return error_template(500, ex)
    end

    page_count = (playlist.video_count / 100).to_i
    page_count += 1 if (playlist.video_count % 100) > 0

    if page > page_count
      return env.redirect "/playlist?list=#{plid}&page=#{page_count}"
    end

    if playlist.privacy == PlaylistPrivacy::Private && playlist.author != user.try &.email
      return error_template(403, "This playlist is private.")
    end

    begin
      videos = get_playlist_videos(playlist, offset: (page - 1) * 100)
    rescue ex
      return error_template(500, "Error encountered while retrieving playlist videos.<br>#{ex.message}")
    end

    if playlist.author == user.try &.email
      env.set "remove_playlist_items", plid
    end

    templated "playlist"
  end

  def self.mix(env)
    locale = env.get("preferences").as(Preferences).locale

    rdid = env.params.query["list"]?
    if !rdid
      return env.redirect "/"
    end

    continuation = env.params.query["continuation"]?
    continuation ||= rdid.lchop("RD")

    begin
      mix = fetch_mix(rdid, continuation, locale: locale)
    rescue ex
      return error_template(500, ex)
    end

    templated "mix"
  end
end
