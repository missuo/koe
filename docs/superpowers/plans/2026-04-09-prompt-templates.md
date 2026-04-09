# Prompt Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add prompt template selection to the Koe overlay, allowing users to rewrite ASR text with alternative prompts (translate, tweet, Xiaohongshu, etc.) after default LLM correction.

**Architecture:** Rust core handles config parsing and LLM rewrite calls. ObjC overlay becomes interactive during the template selection phase. AppDelegate coordinates number key monitoring and rewrite flow.

**Tech Stack:** Rust (koe-core), Objective-C (KoeApp), cbindgen

**Spec:** `docs/superpowers/specs/2026-04-09-prompt-templates-design.md`

---

## Task Overview

1. Rust config: PromptTemplate struct + parsing
2. Rust FFI: rewrite callback + template query
3. Rust core: rewrite function + template JSON
4. ObjC Bridge: rewrite callback + methods
5. Overlay: template button drawing + interaction
6. AppDelegate: rewrite flow coordination + number key monitoring
7. Integration build + test
