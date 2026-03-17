# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- Magic-link tokens are no longer consumed by Slack's link-preview bot. `AuthController` now
  returns a neutral HTML response (without marking the token used) when the request `User-Agent`
  contains `Slackbot`.
