FROM ruby:2.5

COPY Gemfile Gemfile.lock /
RUN bundle install --no-deployment
COPY app.rb config.ru /
COPY views /views
COPY public /public

ENV RACK_ENV=production

CMD ["ruby", "app.rb", "-o", "0.0.0.0"]
