# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- figure out how to infer system timezone so it doesn't need to live in the config

### Changed

- Improve the `mix todo` tasks

- Restructure project conventions into agent-agnostic AGENTS.md hub
- Rewrite CLAUDE.md as thin pointer to AGENTS.md
- Move docs from docs/superpowers/ to docs/plans/ and docs/specs/
- `mix todo` commits pending changes on main before branching — should stash or branch first so work ends up on the PR branch, not main
