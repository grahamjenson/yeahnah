#Yeah, Nah

> "*Yeah, Nah*": New Zealand saying meaning yes, no, or maybe.

Yeah, Nah is a movie recommendations application which you can see hosted at [http://yeahnah.maori.geek.nz/](http://yeahnah.maori.geek.nz/).

It is implemented using:

1. [Good Enough Recommendations Engine (GER)](https://github.com/grahamjenson/ger)
2. [Hapi.js](http://hapijs.com/)
3. [The Movie DB](https://www.themoviedb.org/)

The code is designed to be very minimal (e.g. using CDNs) sacrificing some better practices to have a simplier codebase.

To run it you will need to specifiy a bunch of environment variables:

```
DATABASE_URL=postgresql://root:12345@127.0.0.1/yeahnah \
MOVIEDB_API_KEY=************ \
AMAZON_ID=************ \
AMAZON_SECRET=************ \
AMAZON_TAG=************ \
ITUNES_TAG=************ \
TWITTER_CONSUMER_KEY=************ \
TWITTER_CONSUMER_SECRET=************ \
SESSION_PWD=************ \
coffee index.coffee
```

All Contributions are Welcome :)
