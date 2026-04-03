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

This project uses **three primary documentation files**, separated by role to avoid merge conflicts.

## context.md

This file describes:

- What the product is
- The goals of the application
- Major system concepts
- Development roles and boundaries

This document should remain **high-level** and **avoid implementation details** whenever possible.

---

## architecture-frontend.md

**Maintained by Dev A (Frontend/Canvas)**

The `architecture-frontend.md` file documents **how the UI and canvas systems are implemented**.

Examples of content that belongs there include:

- Canvas rendering strategy
- Gesture handling
- UI component architecture
- SwiftUI view structures
- Visual design specifications
- Animation implementations

This file is **owned by Dev A** and should not be modified by Dev B unless coordinating on integration points.

---

## architecture-backend.md

**Maintained by Dev B (Data/Persistence)**

The `architecture-backend.md` file documents **how data storage and system infrastructure is implemented**.

Examples of content that belongs there include:

- Data models and schemas
- Persistence strategies
- Storage layer architecture
- Spatial indexing systems
- Service layer APIs
- Database structures

This file is **owned by Dev B** and should not be modified by Dev A unless coordinating on integration points.

---

# How Developers and Agents Should Update Documentation

## When to update architecture-frontend.md (Dev A)

Update `architecture-frontend.md` when:

- A UI component implementation becomes stable
- A canvas interaction pattern is finalized
- Visual design decisions are confirmed
- Gesture handling is implemented
- View architecture changes

Examples:

- Finalized canvas gesture system
- Toolbar component specifications
- Animation timing and transitions
- Grid rendering implementation

---

## When to update architecture-backend.md (Dev B)

Update `architecture-backend.md` when:

- A data model is finalized
- Persistence strategy is implemented
- Storage schema is defined
- Service APIs are established
- Infrastructure decisions are made

Examples:

- Canvas element data structure
- Tile-based indexing system
- Persistence service API
- Database schema

---

## When to update context.md (Both)

Update `context.md` when:

- Product goals change
- Major features are added
- Platform strategy changes
- Core concepts evolve
- Development roles are adjusted

**Both Dev A and Dev B** may update this file, but should coordinate to avoid conflicts.

---

## Integration Points Documentation

Both architecture files should include an **"Integration Points"** section documenting:

- Where frontend and backend connect
- Required data conversions
- Shared protocols or interfaces
- Coordination requirements

This helps both devs understand the boundaries and dependencies.

---

## Important Principle

Avoid documenting **speculative architecture**.

Instead:

1. Implement the feature
2. Confirm the solution works
3. Document the finalized approach in the appropriate architecture file

---

## Avoiding Merge Conflicts

**By separating architecture documentation:**

- Dev A can update frontend architecture independently
- Dev B can update backend architecture independently
- Both can work in parallel without file conflicts
- Integration points are clearly marked in both files

**Best practices:**

- Only update your architecture file (unless coordinating)
- Mark integration points clearly
- Update context.md collaboratively when needed
- Use clear section headers for easy navigation

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

# Known Concerns for Dev B

> **Agent instruction:** After reading this section and resolving or acknowledging the items below, delete this entire "Known Concerns for Dev B" section from `context.md` to keep the document clean.

## .refboard UTType runtime warning

The custom `.refboard` UTType is declared in code (`BoardExportDocument.swift`) but was never registered in the app's Info.plist. This produces a runtime warning on every launch:

> Type "AxI.SuperCoolArtReferenceTool.refboard" was expected to be declared and exported in the Info.plist

A reference for the required plist entries exists in `SuperCoolArtReferenceTool/App/InfoPlist_Refboard_Additions.md`.

This may or may not still be relevant — if the board export/import functionality changes or gets reworked, this concern may resolve itself. Just flagging it so Dev B is aware.

---

# Summary

This project aims to create a **reference organization workspace for creatives** built around an interactive infinite canvas.

The primary goals are:

- Smooth canvas interaction
- Flexible spatial organization
- Reliable offline operation
- A simple and intuitive user experience

Implementation details will evolve during development and should be documented in **architecture.md** once decisions become stable.
