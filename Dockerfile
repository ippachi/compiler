FROM ruby:2.6.3

RUN apt-get update && apt-get install -y build-essential gcc-multilib

WORKDIR /app
