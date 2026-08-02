# Product Requirements Document (PRD)

# Pictalis (MVP)

## Overview

A mobile-first photo curation app that helps users quickly identify their favorite photos from a large batch using rapid head-to-head comparisons powered by an Elo-style ranking system.

The app is designed for casual users reviewing 100–300 photos from:

* trips
* graduation shoots
* parties
* events
* casual photography sessions

The product prioritizes:

* low friction
* fast decision-making
* emotionally resonant results
* minimal AI complexity

The app is not intended for:

* professional photographers
* RAW editing workflows
* cloud photo management
* long-term photo storage

---

# Problem Statement

Users routinely capture hundreds of photos but rarely revisit or curate them because reviewing large batches manually is exhausting.

Traditional gallery selection interfaces require:

* excessive scrolling
* repetitive tapping
* difficult absolute judgments

Humans make preference decisions faster through direct comparison than through independent scoring.

The product solves:

> “Help users quickly find the photos they’ll actually come back to.”

---

# Goals

## Primary Goal

Enable users to identify their top 10–20 favorite photos from a batch of 100–300 images within a few minutes.

## Secondary Goals

* Reduce cognitive load during photo review
* Minimize repetitive comparison fatigue
* Surface diverse final selections
* Preserve user control over final results

---

# Non-Goals (MVP)

The MVP will NOT support:

* video ranking
* collaborative ranking
* desktop workflows
* offline support
* global taste modeling across sessions
* AI-generated aesthetic scoring
* permanent cloud photo storage
* social networking features

---

# Target User

## Primary User

Casual iPhone users aged 18–35 who frequently take many photos and struggle to curate them afterward.

Example scenarios:

* graduation photo dump
* weekend trip
* concert
* birthday party
* vacation
* friend group photos

---

# User Stories

## Core User Stories

### Upload Session

As a user, I want to select a batch of photos from my camera roll so I can quickly curate my favorites.

### Fast Comparison

As a user, I want to rapidly choose between two photos so that ranking feels lightweight and intuitive.

### Reduced Redundancy

As a user, I do not want to repeatedly compare near-identical photos early in the process.

### Final Selection

As a user, I want the app to identify my strongest photos without forcing me to rank every image.

### User Control

As a user, I want to manually pin or remove photos from the final set.

### Recovery

As a user, I want my ranking session to persist temporarily if I leave the app.

---

# Core Product Experience

## 1. Session Creation

User:

* opens app
* selects 100–300 photos from iOS photo picker

System:

* compresses images client-side
* uploads compressed working copies

Original photos remain on-device.

---

## 2. Lightweight Processing

Backend processing:

* thumbnail generation
* image embedding generation
* duplicate clustering
* blur/invalid image detection

The system may suppress:

* accidental black images
* severe blur
* obvious duplicates

The system will NOT automatically determine “best” photos using AI.

---

## 3. Optional Cull Stage

Before ranking begins, the user chooses how to start:

* **Filter then rank** — a lightweight swipe-style pass where the user quickly keeps or drops each photo before any pairwise comparisons happen
* **Rank only** — skip straight to the Ranking Experience with all uploaded photos

Behavior:

* dropped photos are excluded from all pairwise comparisons and the final ranked results
* this stage is local-first and fast: decisions are batched and submitted without blocking the user's swiping pace
* skipping this stage has no effect on ranking behavior — it is purely an optional pre-filter

---

## 4. Ranking Experience

### Interaction Model

Users are shown:

* two photos side-by-side

User selects:

* preferred photo

No swipe gestures required in MVP.

### Ranking Logic

Backend updates:

* Elo-style ranking score
* uncertainty/confidence score

The system dynamically chooses future comparisons to maximize ranking confidence while minimizing total comparisons.

---

## 5. Multi-Stage Ranking Flow

### Stage 1 — Broad Discovery

Goal:

* identify strong candidates quickly

Behavior:

* broad photo coverage
* high Elo movement
* low precision

### Stage 2 — Refinement

Goal:

* refine likely top-ranked images

Behavior:

* compare similarly ranked photos
* improve confidence near top set

### Stage 3 — Alternate Selection

Goal:

* choose among near-duplicate finalists

Behavior:

* revisit duplicate clusters attached to top-ranked photos

---

## 6. Completion State

The ranking session ends when:

* top-ranked set stabilizes
* confidence threshold reached
* comparison fatigue threshold reached

System displays:

* “Your favorites are ready.”

User can:

* pin favorites
* remove selections
* reveal alternates
* export/share selected images

---

# Functional Requirements

## Photo Upload

* User can upload 100–300 images per session
* Images compressed before upload
* Upload should begin immediately after selection

## Ranking

* Pairwise comparison interface
* Real-time ranking updates
* Dynamic comparison generation

## Duplicate Handling

* Near-duplicate clustering required
* Duplicate suppression only during early ranking stages
* Alternates must remain accessible

## Session Persistence

* Sessions persist temporarily (24–72 hours)
* Users can resume interrupted sessions

## Export

Users can:

* save favorites
* share favorites
* export selected images back to camera roll

---

# Non-Functional Requirements

## Performance

* Time-to-first-comparison < 10 seconds
* Comparison transition latency < 200ms
* Ranking updates near real-time

## Scalability

Initial MVP target:

* <100k monthly active users

System should support:

* asynchronous processing
* stateless API scaling
* temporary object storage

## Privacy

* Original photos remain on-device
* Uploaded working copies auto-delete after retention window
* No permanent cloud archive

---

# Technical Architecture (MVP)

## Client (iOS)

Responsibilities:

* photo selection
* image compression
* upload orchestration
* ranking UI
* local thumbnail cache

Framework:

* SwiftUI

---

## Backend

Single backend service architecture.

Responsibilities:

* upload handling
* ranking orchestration
* session management
* image processing coordination

Suggested stack:

* Supabase or equivalent lightweight backend platform

---

## Storage

Temporary cloud object storage:

* compressed uploads
* thumbnails

Auto-delete after retention window.

---

## Processing Pipeline

### Upload Service

Handles:

* image upload
* metadata extraction

### Processing Worker

Generates:

* embeddings
* duplicate clusters
* quality flags

### Ranking Engine

Maintains:

* Elo ratings
* uncertainty/confidence
* comparison selection

---

# Ranking System

## Inputs

* pairwise user choices
* duplicate cluster information

## Outputs

* ranked image list
* confidence scores

## Ranking Constraints

The system should:

* minimize required comparisons
* maximize confidence in top-ranked images
* avoid over-surfacing duplicate compositions

---

# Success Metrics

## Primary Metric

Median time required to produce a satisfactory top-photo set.

## Secondary Metrics

* session completion rate
* comparisons per completed session
* top-photo export rate
* D1/D7 retention
* percentage of sessions resumed after interruption

---

# Risks

## Comparison Fatigue

Too many comparisons will reduce completion rates.

Mitigation:

* intelligent pair selection
* duplicate suppression
* early convergence detection

## Trust

Users may reject AI-driven choices.

Mitigation:

* AI only reduces redundancy
* user can always override rankings

## Upload Friction

Long preprocessing delays may cause churn.

Mitigation:

* progressive upload pipeline
* start ranking before full upload completes

---

# Future Opportunities (Post-MVP)

* collaborative ranking
* friend voting
* personalized aesthetic models
* social sharing
* smart album generation
* Android support
* desktop/web support
* Lightroom export integrations
* video support
* multimodal “memory” ranking modes