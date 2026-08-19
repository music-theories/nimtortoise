# Nim Tortoise Language Server

## "Slow and steady wins the race"

A Language Server for `nim` that prioritises correctness over speed.

A fork and rewrite of [`nimlangserver`](https://github.com/nim-lang/langserver). It aims to solve a number of problems when using the combination of `nimlangserver` and its accompanying VS Code extension on large projects, especially monorepos containing a number of different Nim packages.

Earlier in this project, pull requests for many of the improvements were submitted to the main `nimlangserver` repository. Over time, however, it became clear that several architectural choices in the original necessitated a ground-up rewrite of its internals.

---

## Setup

```
nimble install
nimble setup
```

## Building

```
nimble build
```

---

## Acknowledgments

This work would not be possible without the original work by Konstantin Molchanov and the continued work by the core Nim team.
