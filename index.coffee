bb = require 'bluebird'
Hapi = require 'hapi'
g = require 'ger'
_ = require 'underscore'
GER = g.GER
knex = g.knex
PsqlESM = g.PsqlESM
Joi = require 'joi'
AmazonHelper = require('apac').OperationHelper;
request = require 'request'

process.env.DATABASE_URL = process.env.DATABASE_URL
process.env.REDIS_URL = process.env.REDIS_URL

red = require("url").parse(process.env.REDIS_URL)
cache_config  = { engine: require('catbox-redis')}
cache_config.host = red.hostname
cache_config.port = red.port
cache_config.password = red.auth.split(":")[1] if red.auth


Utils = {}

Utils.handle_error = (logger, err, reply) ->
  if err.isBoom
    logger.log(['error'], err)
    reply(err)
  else
    console.log "Unhandled Error", err, err.stack
    logger.log(['error'], {error: "#{err}", stack: err.stack})
    reply({error: "An unexpected error occurred"}).code(500)


class YeahNah

  constructor: () ->
    bb.try( => @init_server())
    .then( => @load_server_plugins())
    .then( => @setup_server())
    .then( => @add_server_methods())
    .then( => @add_server_routes())

  init_server: () ->
    #SETUP SERVER
    port = process.env.PORT || 4567;
    @_server = new Hapi.Server('0.0.0.0', port, {
      cache: cache_config
      state:
        cookies:
          clearInvalid: true
          strictHeader: false
    })

    @knex = knex(
      client: 'pg', 
      connection: process.env.DATABASE_URL
    )

    @esm = new PsqlESM('yeahnah', {knex : @knex})

    @ger = new GER(@esm, {
      minimum_history_limit: 1,
      similar_people_limit: 25,
      related_things_limit: 20
      recommendations_limit: 40,
      recent_event_days: 14,
      previous_actions_filter: ['save', 'like','hate','duno'],
      compact_database_person_action_limit: 1000
      compact_database_thing_action_limit: 10000
      person_history_limit: 200
      crowd_weight: 0
    })

    @mdb = require('moviedb')(process.env.MOVIEDB_API_KEY);

    @amazon = new AmazonHelper({ awsId: process.env.AMAZON_ID, awsSecret: process.env.AMAZON_SECRET, assocId: process.env.AMAZON_TAG})
    true

  setup_server: ->
    
    @_server.auth.strategy('twitter', 'bell', {
      provider: 'twitter',
      password: process.env.SESSION_PWD,
      clientId: process.env.TWITTER_CONSUMER_KEY,
      clientSecret: process.env.TWITTER_CONSUMER_SECRET,
      isSecure: false
    })
    

  add_server_routes: () ->

    @_server.route(
      method: ['GET', 'POST'],
      path: '/sign_in_with_twitter',
      config:
        auth: 'twitter',
        handler: (request, reply) ->
          if request.auth.credentials && request.auth.credentials.profile && request.auth.credentials.profile.id
            request.session.set('tid', request.auth.credentials.profile.id)
          return reply.redirect('/');
    )

    @_server.route(
      method: 'GET'
      path: '/liked'
      handler: (request, reply) =>
        person = request.session.get('tid') || request.state.session.id
        @ger.find_events(person, 'like')
        .then( (events) =>
          promises = []
          movie_ids = _.uniq((e.thing for e in events)) 
          for id in movie_ids
            promises.push @server_method('get_movie_info', [id]).error((e) -> console.log e.status)
          bb.all(promises)
        )
        .then((movies) ->
          reply(movies)
        )
    )

    @_server.route(
      method: 'GET'
      path: '/saved'
      handler: (request, reply) =>
        person = request.session.get('tid') || request.state.session.id
        @ger.find_events(person, 'save')
        .then( (events) =>
          promises = []
          movie_ids = _.uniq((e.thing for e in events)) 
          for id in movie_ids
            promises.push @server_method('get_movie_info', [id]).error((e) -> console.log e.status)
          bb.all(promises)
        )
        .then((movies) ->
          reply(movies)
        )
    )

    @_server.route(
      method: 'POST',
      path: '/event',
      config:
        validate:
          payload: Joi.object().keys(
              action: Joi.string().min(1).max(10).regex(/save|like|hate|duno/).required()
              movie: Joi.string().min(1).max(10).regex(/\d/).required()    
          )

      handler: (request, reply) =>
        action = request.payload.action
        thing = request.payload.movie

        if request.session.get('tid')
          person = request.session.get('tid')
          expires_at = null
        else
          person = request.state.session.id 
          one_day = 24*60*60*1000
          expires_at = new Date((new Date()).getTime() + (one_day*7))

        console.log "Event", person, action, thing, {expires_at: expires_at}

        @ger.event(person, action, thing, {expires_at: expires_at})
        .then( ->
          reply({success: true})
        )
    )


    @_server.route(
      method: 'GET',
      path: '/recommendations',
      handler: (request, reply) =>
        person = request.session.get('tid') || request.state.session.id
        
        bb.all([@ger.recommendations_for_person(person, 'like'), @random_movies()])
        .spread( (recs, randoms) =>
          console.log JSON.stringify(recs, null, 2)
          real_recs = (r.thing for r in recs.recommendations)
          randoms = randoms[...5] #shuffle in a few wild cards

          _.shuffle(real_recs.concat(randoms))[0..20]
        )
        .then( (movie_ids) =>
          promises = []
          movie_ids = _.uniq(movie_ids)
          
          for id in movie_ids
            promises.push @server_method('get_movie_info', [id]).error((e) -> console.log e.status)
          bb.all(promises)
        )
        .then( (movie_infos) ->
          movie_infos = movie_infos.filter((m) ->
            m && m.status == "Released" && m.trailer_url && m.poster_url && m.backdrop_url && m.rating > 0
          )

          movie_infos = movie_infos[...10]
          
          ret = {
            config: {}
            recommendations: movie_infos
          }

          ret.config.signed_in = true if request.session.get('tid') 
          reply(ret)
        )
    )

    

    @_server.route(
      method: 'GET',
      path: '/',
      handler: {
          file: 'index.html'
      }
    )

  add_server_methods: ->
    ONE_DAY = 24 * 60 * 60 * 1000

    @_server.method(
      'mdb_configuration'
      (next) => @mdb.configuration(next) 
      {
        cache:
          expiresIn: ONE_DAY * 7
      }
    )

    @_server.method(
      'mdb_popular_movies'
      (page, next) => @mdb.miscPopularMovies({page: page}, next) 
      {
        cache:
          expiresIn: ONE_DAY
      }
    )

    @_server.method(
      'mdb_rated_movies'
      (page, next) => @mdb.miscTopRatedMovies({page: page}, next) 
      {
        cache:
          expiresIn: ONE_DAY * 7
      }
    )

    @_server.method(
      'mdb_movie_info'
      (id, next) => @mdb.movieInfo({id: id}, next)
    )

    @_server.method(
      'mdb_movie_trailer'
      (id, next) => @mdb.movieTrailers({id: id}, next)
    )

    @_server.method(
      'amazon_movie'
      (title, next) => @amazon.execute('ItemSearch', {'SearchIndex': 'DVD', 'Keywords': title}, next)
    )

    @_server.method(
      'itunes_movie'
      (title, next) =>
        title = encodeURIComponent(title)
        url = "https://itunes.apple.com/search?term=#{title}&limit=1&media=movie"
        request.get(url , (e,r,b) -> 
          if b == ''
            next(e, null)
          else
            next(e, JSON.parse(b))
        )
    )

    @_server.method(
      'get_movie_info'
      (id, next) =>
        bb.all([@server_method('mdb_movie_info', [id]), @server_method('mdb_movie_trailer', [id])])
        .spread( (movie, trailers) =>
          console.log "Made MOVIE #{id} #{movie.title}"
          genres = movie.genres.map( (g) -> g.name)

          date = movie.release_date.substring(0,4)
          new_movie = {
            id: movie.id
            title : movie.title
            genres: genres
            tagline: movie.tagline
            overview: movie.overview 
            movie_url: movie.homepage
            rating: movie.vote_average
            release_date: date
            status: movie.status
          }

          trailer = trailers.youtube.filter((t) -> t.type == 'Trailer')[0]

          new_movie.trailer_url = "http://www.youtube.com/embed/#{trailer.source}" if trailer && trailer.source
          new_movie.imdb_url = "http://www.imdb.com/title/#{movie.imdb_id}" if movie.imdb_id
          new_movie.poster_url = "#{@mdb.base_url}w342#{movie.poster_path}" if movie.poster_path && movie.poster_path != ""
          new_movie.backdrop_url = "#{@mdb.base_url}w780#{movie.backdrop_path}" if movie.backdrop_path && movie.backdrop_url != ""

          #adding some additional actions
          for genre in genres
            @ger.event(genre, 'like', movie.id)

          bb.all([new_movie, @server_method('amazon_movie', [movie.title]), @server_method('itunes_movie', [movie.title])])
          #amazon link
          #itunes link
        )
        .spread((movie, amazon_resp, itunes_resp) ->
          
          response = amazon_resp.ItemSearchResponse || {}
          items = (response.Items || [{}])[0]
          first_result = (items.Item || [{}])[0]
          movie.amazon_url = (first_result.DetailPageURL || [])[0]

          if itunes_resp && itunes_resp.resultCount > 0
            result = itunes_resp.results[0]
            movie.itunes_url = result.trackViewUrl || result.collectionViewUrl
            movie.itunes_url += "&at=#{process.env.ITUNES_TAG}"

          next(null, movie)
        )
        .error((e) ->
          next(e, null)
        )
      {
        cache:
          expiresIn: ONE_DAY * 7
      }
    )

  random_movies: ->
    method = _.sample(['mdb_popular_movies', 'mdb_rated_movies'])
    page = _.sample([1..40])
    @server_method(method, [page])
    .then( (results) =>
      movie_ids = []
      for movie in results.results
        movie_ids.push movie.id
      _.shuffle(movie_ids) 
    )

  bootstrap: ->
    ps = []
    n = 60
    for method in ['mdb_popular_movies', 'mdb_rated_movies']
      for page in [1..n]
        ps.push(@server_method(method, [page])
        .then( (results) =>
          promises = []
          movie_ids = []
          for movie in results.results 
            do (movie) =>
              promises.push bb.delay(Math.random() * n * 3000).then( => @server_method('get_movie_info', [movie.id]))
          bb.all(promises)
        ))

    bb.all(ps)


  server_method: (method, args = []) ->
    d = bb.defer()
    @_server.methods[method].apply(@, args.concat((err, result) ->
      if (err)
        d.reject(err)
      else
        d.resolve(result)
    ))
    d.promise

  find_or_create_schemas: (schema) ->
    @knex.raw("SELECT schema_name FROM information_schema.schemata WHERE schema_name = '#{schema}'")
    .then( (result) =>
      exists = result.rows.length >= 1
      if !exists
        @esm.initialize()
      else
        true
    )

  start: ->
    @find_or_create_schemas('yeahnah')
    .then( => 
      @server_method('mdb_configuration')
      .then((configuration) => @mdb.base_url = configuration.images.base_url)
    )
    .then( =>
      bb.all([
        @ger.action('save', 0)
        @ger.action('like', 5)
        @ger.action('duno', 0)
        @ger.action('hate', 10)
      ])
    )
    .then( => @start_server())

  stop: ->
    @stop_server()

  load_server_plugins: ->
    @load_server_plugin('yar', {cookieOptions: { password: process.env.SESSION_PWD}})
    .then( =>
      @load_server_plugin('bell')
    )

  load_server_plugin: (plugin, options = {}) ->
    d = bb.defer()
    @_server.pack.register({plugin: require(plugin), options: options}, (err) ->
      if (err)
        d.reject(err)
      else
        d.resolve()
    )
    d.promise

  start_server: ->
    d = bb.defer()
    @_server.start( =>
      d.resolve(@)
    )
    d.promise

  stop_server: ->
    d = bb.defer()
    @_server.stop( ->
      d.resolve()
    )
    d.promise.then(=> @knex.destroy(->); @redis.end() )


if process.env.BOOTSTRAP
  yeahnah = new YeahNah()
  yeahnah.bootstrap()
  .then( ->
    console.log "finished bootstraping"
  )
  .finally( ->
    process.exit(1);
  )
else if process.env.COMPACT
  yeahnah = new YeahNah()
  yeahnah.ger.compact_database()
  .then( ->
    console.log "finished compacting"
  )
  .finally( ->
    process.exit(1);
  )
else
  yeahnah = new YeahNah()
  yeahnah.start().catch((e) -> console.log "ERROR",e)
