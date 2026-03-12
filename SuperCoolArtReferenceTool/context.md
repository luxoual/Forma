# Project Context

## Overview

This project is an **iPad-based Art Reference Board application** designed to help users organize visual inspiration on a large, flexible canvas.

The application allows users to create boards where they can place and arrange visual references such as:

- Images
- GIFs
- Videos
- Text notes

Items can be freely positioned and organized on a canvas that supports navigation and spatial layout.

The goal of the product is to create a **visual workspace for artists, designers, and creatives** who need to collect and arrange references in a spatial and intuitive way.

The application is currently being developed as an **offline-first iPadOS application**.

---

# Core Problem

Creative professionals frequently gather large numbers of visual references while working on projects.

Common issues with existing workflows include:

- References scattered across folders or browser tabs
- Limited spatial organization tools
- Difficulty arranging references visually
- Poor offline support
- Tools optimized for drawing instead of reference collection

This application aims to solve these problems by providing:

- A **freeform visual canvas**
- Fast and intuitive media placement
- Reliable offline operation
- A workspace optimized for organizing references visually

---

# Product Concepts

## Boards

Users can create multiple **boards**.

Each board acts as an independent workspace containing:

- Canvas items
- Media references
- Notes

Boards allow users to organize references by project, topic, or theme.

---

## Infinite Canvas

Each board contains a navigable canvas where users can:

- Pan across the workspace
- Zoom in and out
- Arrange items spatially
- Organize references visually

The canvas should behave as if it is effectively infinite from the user's perspective.

The **exact implementation strategy for the infinite canvas is intentionally not fixed here** and will be defined in the architecture documentation as development progresses.

---

## Canvas Items

Items placed on the canvas may include:

- Images
- GIFs
- Videos
- Text annotations

Items should support interactions such as:

- Repositioning
- Resizing
- Rotation
- Layer ordering

Exact item structures will evolve as the application is implemented.

---

# Platform

The application is currently being developed as a **native iPadOS application** using:

- Swift
- SwiftUI
- Xcode

The initial focus is **iPad-only**.

Future platform expansion may be evaluated later.

---

# Offline First Philosophy

The application is designed to work **fully offline**.

This means:

- Boards should be accessible without internet connectivity
- Media assets should remain available locally
- Core functionality should not depend on network services

The specific implementation of persistence and storage is intentionally left flexible until implemented.

---

# Development Structure

Development is currently split between two primary roles.

## Dev A — Frontend / Canvas Interaction

Responsible for:

- Canvas rendering
- SwiftUI views
- Gesture interactions
- Canvas item manipulation
- Visual UI components

Dev A focuses primarily on **interaction and presentation**.

---

## Dev B — Data / Persistence / Infrastructure

Responsible for:

- Data models
- Media ingestion
- Local storage
- Board persistence
- System utilities

Dev B focuses primarily on **data structures and underlying logic**.

---

# Agent Role Identification

AI agents working in this repository must first determine **which development role they are acting as** before performing implementation tasks.

Before beginning work, the agent should ask the user:

> **"Are you working as Dev A (Frontend / Canvas) or Dev B (Data / Persistence)?"**

Once the role is identified, the agent should scope its work accordingly.

---

## Dev A Responsibilities

Dev A typically works in areas related to **user interaction and visual behavior**, including:

- Canvas rendering
- SwiftUI view logic
- Gesture handling
- Canvas item manipulation
- UI components

Typical directories for Dev A work include:

- `Features/`
- `UIComponents/`
- Canvas view-related files

---

## Dev B Responsibilities

Dev B typically works in areas related to **data, storage, and infrastructure**, including:

- Data models
- Media import pipelines
- File storage
- Board persistence
- Core system utilities

Typical directories for Dev B work include:

- `Models/`
- `Persistence/`
- `Services/`

---

# Agent Behavior Rules

AI agents should follow these rules when modifying the repository:

1. Prompt the user to determine whether the work is **Dev A or Dev B**.
2. Scope changes to the directories associated with that role.
3. Avoid modifying the other role's systems unless explicitly instructed.
4. Prefer minimal, focused changes instead of broad refactors.

This helps maintain a **clear separation between UI logic and system logic**.

---

# Documentation System

This project uses two primary documentation files.

## context.md

This file describes:

- What the product is
- The goals of the application
- Major system concepts
- Development roles and boundaries

This document should remain **high-level** and **avoid implementation details** whenever possible.

---

## architecture.md

The `architecture.md` file documents **how the system is implemented**.

Examples of content that belongs there include:

- Canvas rendering strategy
- Coordinate systems
- Media storage strategies
- Data models
- Performance techniques

Unlike `context.md`, the architecture document is expected to **evolve frequently** as development progresses.

---

# How Developers and Agents Should Update Documentation

## When to update architecture.md

Update `architecture.md` when:

- A subsystem implementation becomes stable
- A technical decision is finalized
- The system behavior is confirmed in code

Examples:

- Finalized canvas coordinate system
- Confirmed media storage approach
- Persistence architecture

---

## When to update context.md

Update `context.md` when:

- Product goals change
- Major features are added
- Platform strategy changes
- Core concepts evolve

---

## Important Principle

Avoid documenting **speculative architecture**.

Instead:

1. Implement the feature
2. Confirm the solution works
3. Document the finalized approach in `architecture.md`

---

# Current MVP Scope

The MVP aims to support:

- Board creation
- Canvas navigation
- Media placement
- Text annotations
- Offline persistence

Features intentionally **out of scope for MVP** include:

- Real-time collaboration
- Cloud synchronization
- Public sharing
- Advanced editing tools

---

# Future Evolution

Potential future directions include:

- Collaboration
- Cloud backup
- Board export
- AI-assisted organization

These ideas are exploratory and **not guaranteed roadmap items**.

---

# Summary

This project aims to create a **reference organization workspace for creatives** built around an interactive infinite canvas.

The primary goals are:

- Smooth canvas interaction
- Flexible spatial organization
- Reliable offline operation
- A simple and intuitive user experience

Implementation details will evolve during development and should be documented in **architecture.md** once decisions become stable.
