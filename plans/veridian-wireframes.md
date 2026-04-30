# Veridian — Document 10 of 10: UI/UX Wireframes

**Project:** Veridian All-in-One Service Booking Platform  
**Version:** 1.0.0  
**Status:** Authoritative — all Flutter widget implementations and Next.js component builds derive from this document  
**Applies to:** Flutter mobile (light + dark theme), Next.js web (light theme only)

---

## Design System Foundation

### Color Tokens

The Veridian design system is anchored in dark forest green — a colour that reads as professional, trustworthy, and connected to health and nature without the clinical sterility of blue/white medical aesthetics.

#### Forest Green Palette

| Token name     | Hex       | Usage                                                                                    |
| -------------- | --------- | ---------------------------------------------------------------------------------------- |
| `forest-900`   | `#0D3B2E` | Primary brand colour, nav bar bg, primary buttons (light theme), surface bg (dark theme) |
| `forest-700`   | `#1A5C46` | Secondary text on light, section headers, links                                          |
| `forest-500`   | `#2ECC8F` | Accent / CTA (dark theme), verified badges, active states, dark theme nav text           |
| `forest-100`   | `#E8F5F0` | Light tint background, card hover state, success-adjacent fills                          |
| `forest-50`    | `#F0FAF6` | Page background (light theme), input backgrounds, card fills                             |
| `forest-muted` | `#A3C4B8` | Muted/secondary text, idle nav links, placeholder text                                   |

#### Semantic Colours (both themes)

| Semantic | Light                 | Dark                    | Usage                                            |
| -------- | --------------------- | ----------------------- | ------------------------------------------------ |
| Warning  | `#FAEEDA` / `#633806` | `#63380622` / `#FAC775` | Pending payment, slot ⚠ May vary, offline banner |
| Danger   | `#FCEBEB` / `#791F1F` | `#A32D2D22` / `#F09595` | Cancelled status, error states, revoke action    |
| Success  | `#EAF3DE` / `#27500A` | `#27500A22` / `#97C459` | Completed status, verified badges                |

#### Theme Application

**Light theme** (web + mobile light mode):

- Backgrounds: `#FFFFFF` (primary), `#F0FAF6` (secondary)
- Text: `#0D3B2E` (primary), `#1A5C46` (secondary), `#A3C4B8` (muted)
- Borders: `#A3C4B8` at 0.5px
- CTAs: `background: #0D3B2E; color: #E8F5F0`
- Navigation bar: `background: #0D3B2E`

**Dark theme** (mobile dark mode only — web is light only):

- Backgrounds: `#0D3B2E` (primary surface), `#163320` (elevated surface), `#0F2A22` (nav bar)
- Text: `#E8F5F0` (primary), `#A3C4B8` (secondary), `#2ECC8F88` (muted/placeholder)
- Borders: `#2ECC8F44` at 0.5px
- CTAs: `background: #2ECC8F; color: #0D3B2E`
- Active indicators: `#2ECC8F`

### Typography

| Element           | Font    | Size | Weight | Colour (light) |
| ----------------- | ------- | ---- | ------ | -------------- |
| App/page title    | Outfit  | 20px | 500    | `#0D3B2E`      |
| Section heading   | Outfit  | 15px | 500    | `#0D3B2E`      |
| Body / card title | DM Sans | 13px | 500    | `#0D3B2E`      |
| Body text         | DM Sans | 12px | 400    | `#0D3B2E`      |
| Secondary text    | DM Sans | 11px | 400    | `#1A5C46`      |
| Muted/label text  | DM Sans | 10px | 400    | `#A3C4B8`      |
| Badge/pill text   | DM Sans | 9px  | 500    | varies         |

Flutter: `google_fonts` package, `GoogleFonts.outfit()` + `GoogleFonts.dmSans()`  
Next.js: `next/font/google` — `Outfit` + `DM_Sans`, loaded in `layout.tsx`

### Spacing Scale

```
4px   — micro gap (between badge text and icon)
6px   — tight gap (between card elements)
8px   — component padding
12px  — card internal padding (mobile)
14px  — section gap (mobile)
16px  — card internal padding (web)
20px  — page horizontal padding (web)
24px  — section spacing (web)
```

### Border Radius Scale

```
8px  (rounded-md) — buttons, inputs, small tags
12px (rounded-lg) — cards, doctor cards
20px (rounded-xl) — pill buttons, search bar, CTA buttons
50%               — avatar circles
```

---

## Screen Inventory

### Patient Screens — Mobile (Flutter)

| Screen                         | Route                 | Light | Dark | Priority |
| ------------------------------ | --------------------- | ----- | ---- | -------- |
| Onboarding / splash            | `/`                   | ✓     | ✓    | P0       |
| Registration                   | `/register`           | ✓     | ✓    | P0       |
| OTP verification               | `/verify`             | ✓     | ✓    | P0       |
| Doctor search                  | `/search`             | ✓     | ✓    | P0       |
| Doctor profile                 | `/doctors/:id`        | ✓     | ✓    | P0       |
| Slot picker (step 1)           | `/book/:id/slot`      | ✓     | ✓    | P0       |
| Pre-consultation form (step 2) | `/book/:id/form`      | ✓     | ✓    | P0       |
| Review booking (step 3)        | `/book/:id/review`    | ✓     | ✓    | P0       |
| Payment (step 4)               | `/book/:id/pay`       | ✓     | ✓    | P0       |
| Booking confirmed (step 5)     | `/book/:id/confirmed` | ✓     | ✓    | P0       |
| My appointments                | `/appointments`       | ✓     | ✓    | P0       |
| Appointment detail             | `/appointments/:id`   | ✓     | ✓    | P0       |
| Health timeline                | `/timeline`           | ✓     | ✓    | P0       |
| Add timeline entry             | `/timeline/add`       | ✓     | ✓    | P1       |
| Consent management             | `/profile/consent`    | ✓     | ✓    | P0       |
| Profile & settings             | `/profile`            | ✓     | ✓    | P0       |
| Offline mode indicator         | (global overlay)      | —     | ✓    | P0       |
| Conflict resolution modal      | (global modal)        | ✓     | ✓    | P0       |

### Doctor Screens — Mobile (Flutter)

| Screen                            | Route                                | Light | Dark | Priority |
| --------------------------------- | ------------------------------------ | ----- | ---- | -------- |
| Doctor dashboard                  | `/doctor`                            | ✓     | ✓    | P0       |
| Today's schedule                  | `/doctor/schedule`                   | ✓     | ✓    | P0       |
| Appointment detail (doctor view)  | `/doctor/appointments/:id`           | ✓     | ✓    | P0       |
| Add diagnosis note                | `/doctor/appointments/:id/diagnosis` | ✓     | ✓    | P0       |
| Patient timeline (consented view) | `/doctor/patients/:id/timeline`      | ✓     | ✓    | P1       |
| Availability manager              | `/doctor/availability`               | ✓     | ✓    | P0       |
| Earnings                          | `/doctor/earnings`                   | ✓     | ✓    | P1       |
| Doctor profile edit               | `/doctor/profile`                    | ✓     | ✓    | P0       |

### Patient + Doctor Screens — Web (Next.js)

| Screen                 | Route                     | Notes                                        |
| ---------------------- | ------------------------- | -------------------------------------------- |
| Landing / marketing    | `/`                       | SSR, public                                  |
| Doctor search          | `/doctors`                | SSR + client hydration for slot availability |
| Doctor profile         | `/doctors/[slug]`         | SSR for SEO                                  |
| Booking flow (5 steps) | `/book/[doctorId]/[step]` | CSR, authenticated                           |
| Patient dashboard      | `/dashboard`              | CSR, authenticated                           |
| Patient appointments   | `/appointments`           | CSR, authenticated                           |
| Appointment detail     | `/appointments/[id]`      | CSR, authenticated                           |
| Health timeline        | `/timeline`               | CSR, authenticated                           |
| Doctor dashboard       | `/doctor/dashboard`       | CSR, doctor role                             |
| Doctor schedule        | `/doctor/schedule`        | CSR, doctor role                             |
| Doctor earnings        | `/doctor/earnings`        | CSR, doctor role                             |
| Clinic admin dashboard | `/clinic/dashboard`       | CSR, clinic_admin role                       |
| Auth (login/register)  | `/auth/[...nextauth]`     | Hybrid                                       |

---

## Component Specifications

### DoctorCard (search result card)

**Mobile:**

```
Container: rounded-lg (12px), F0FAF6 fill, 0.5px A3C4B8 border, 10px padding
Layout: Row — Avatar (38×38, 0D3B2E fill) | Column (flex:1) | Right column
Left column:
  - Doctor name: 12px, 500, 0D3B2E
  - Specialization + Clinic: 10px, 400, 1A5C46
  - Stars + rating: 10px, BA7517
Right column:
  - Consultation fee: 10px, 1A5C46
  - Earliest slot pill: 9px, E8F5F0 bg, 0D3B2E text
Verified badge: 9px, E8F5F0 bg, 0D3B2E text, top-right of name row
```

**Web:**

```
Container: rounded-lg (12px), white fill, 0.5px var(--color-border-tertiary), 12px padding
Hover: border-color: 0D3B2E
Layout: Row — Avatar (40×40) | Main column (flex:1) | Price+CTA column
Doctor name: 13px, 500, 0D3B2E
Specialization + Clinic: 11px, 1A5C46
Languages: 11px, muted
Stars + review count: 11px
Slot row (below main content): border-top, flex row of slot pills
Primary CTA slot pill: 0D3B2E fill, E8F5F0 text, 11px
Secondary slot pills: F0FAF6 fill, 0D3B2E text, 0.5px A3C4B8 border
⚠ May vary: opacity 0.4, amber warning badge
```

### AppointmentCard

```
Container: rounded-lg, F0FAF6 fill, 0.5px A3C4B8 border, 10px padding
Status badge: top-left, 9px pill
  - confirmed: E8F5F0 fill, 0D3B2E text
  - pending payment: FAEEDA fill, 633806 text
  - completed: EAF3DE fill, 27500A text
  - cancelled: FCEBEB fill, 791F1F text
Row: Avatar (32×32) | Doctor name (11px 500) + Specialization (10px) + Date/Time/Mode (10px muted)
Countdown: top-right, 9px muted (e.g. "in 2 days", "expires in 8 min")
CTA button (pending payment only): full-width, 0D3B2E fill, 6px padding, 20px radius
```

### SlotPicker

**Mobile:**

- Date strip: Horizontal scroll, 5–7 day pills visible
- Selected date pill: 2ECC8F fill (dark) or 0D3B2E fill (light), 34px wide, 10px height
- Time grid: 3-column, slots as 10px pills
- Available: F0FAF6/163320 fill
- Selected: 0D3B2E/2ECC8F fill, 500 weight
- Booked/taken: 35% opacity
- Confidence warning: amber text, 9px, shown for slots with `confidence_score < 0.6`

### PreConsultationFormRenderer

```
Section header: 10px, 500, 1A5C46 (light) / A3C4B8 (dark), uppercase, 0.5px letter-spacing
Field label: 10px, 500, 1A5C46 / A3C4B8
Text/textarea input: F0FAF6/163320 bg, 0.5px border, 8px radius, 11px text
Select field: Same as input but with ▾ indicator; opens bottom sheet (mobile) / popover (web)
Boolean: Side-by-side Yes/No buttons; selected = 0D3B2E/2ECC8F fill
Number: Input with unit label suffix
Date: Date picker sheet (mobile) / shadcn Calendar popover (web)
Conditional field transition: AnimatedSize + AnimatedOpacity, 250ms
Required marker: * after label text, same colour as label
```

### BottomNavigationBar (Mobile)

```
Height: 52px (44px bar + 8px safe area)
Background: white (light) / 0F2A22 (dark)
Top border: 0.5px, E8F5F0 / 2ECC8F22
Items: 4 — Search, Bookings, Timeline, Profile
Active item: 9px 500 text, 0D3B2E/2ECC8F colour, 4px dot indicator below label
Idle item: 9px 400 text, A3C4B8 / 2ECC8F44 colour
```

### Web Navigation Bar

```
Height: 44px
Background: #0D3B2E (always — this is the only consistently dark element on light-theme web)
Logo: 14px, 500, 2ECC8F, letter-spacing: 0.5px
Nav links: 12px, A3C4B8 (idle) / E8F5F0 (active)
CTA button: 2ECC8F fill, 0D3B2E text, 11px, 16px radius
```

### OfflineBanner

```
Display: when ConnectivityState.offline
Position: Below nav bar, full width
Height: 32px
Background: FAEEDA (light) / 63380622 (dark)
Border: 0.5px EF9F27 / BA751744
Text: "You're offline · N changes queued" — 10px, 633806 / FAC775
Icon: Info circle SVG, 12×12
```

### ConflictResolutionBottomSheet

```
Handle: 32×4px, rounded, A3C4B8, centered at top
Title: 14px, 500, 0D3B2E
Body text: 12px, 400, muted, line-height 1.5
Alternative slots (if applicable): SlotPicker in compact form
Actions: Max 2 buttons, stacked
  Primary: 0D3B2E fill (light) / 2ECC8F fill (dark), full width
  Secondary: Outlined, full width
Backdrop: rgba(0,0,0,0.4)
Spring animation: 300ms, slight bounce (Flutter spring physics)
```

### VerifiedBadge

```
Container: inline-flex, 6px horizontal padding, 2px vertical, rounded-md
Background: E8F5F0 (light) / 2ECC8F22 (dark)
Text: 9px, 500, 0D3B2E (light) / 2ECC8F (dark)
Content: "✓ GMDC" for verified doctors
```

---

## Critical Booking Flow Annotations

### Step 1 — Slot Selection

**Mobile behaviour:**

- Week strip shows 7 days. Days with no available slots show reduced opacity.
- On selecting a date, the slot grid below animates in (300ms slide-up).
- Slots taken by another patient show 35% opacity and are non-tappable.
- Slots with `confidence_score < 0.6` show an amber ⚠ icon.
- The selected slot is visually distinct (filled CTA colour). "Continue" button activates only after slot selection.
- The bottom "Continue" CTA floats above the slot grid with a subtle white gradient above it on light theme (prevents content appearing cut off).

**Web behaviour:**

- Date navigation uses a horizontal calendar week strip at the top of the doctor profile's booking panel.
- Slots render as a pill grid. Hovering a slot highlights it; clicking selects it and activates the "Book this slot" CTA.
- The CTA on the search result card ("Today 2:30 PM") is a direct deep-link to step 1 with that slot pre-selected.

### Step 2 — Pre-Consultation Form

**Key annotation:** The "Continue" button must be disabled until all required visible fields have values. This is enforced client-side in real time — the button does not wait for a submit attempt.

Conditional fields animate in/out using `AnimatedSize` on Flutter and a CSS transition on web. Clearing a hidden field's value happens on field hide, not on submit — the user never sees the clearing happen.

**File upload annotation:** Files upload directly to Supabase Storage before the user taps Continue. A per-file progress indicator is shown. If upload fails, the field shows an error and the Continue button remains disabled until the upload succeeds or the file is removed.

### Step 3 — Review & Confirm

**Cancellation policy must be visible here.** Per the Consumer Protection Act 2023 requirement (Document 9), the cancellation policy is displayed as a distinct card on this screen — not buried in the Terms of Service link. Patients see it before they pay.

The terms acceptance checkbox is unchecked by default (per DPA 2012 consent requirements). The "Continue to payment" button is disabled until checked.

### Step 4 — Payment

**Mobile:** Paystack Flutter SDK handles the in-app payment sheet. Veridian does not render a custom payment form — the Paystack SDK presents the card input UI in a secure bottom sheet. After payment, control returns to Veridian.

**Web:** Paystack inline checkout (popup). The CTA button opens the Paystack checkout popup. On success, the Paystack callback redirects to step 5.

**Offline payment note:** If the user is offline at step 4, the payment buttons are hidden and replaced with an inline message: "Connect to the internet to complete payment." The previously selected slot and form responses are preserved in memory for up to 30 minutes.

### Step 5 — Confirmation

The checkmark animation plays once on screen arrival (Rive or Lottie, 800ms). After the animation completes, the appointment card slides in from below (300ms, spring). Two CTAs: "Add to calendar" (generates `.ics` file) and "Done" (navigates to appointments dashboard).

---

## Offline State Design

### Visual treatment

**Search screen while offline:**

- Offline banner appears at top of content
- Saved doctors section appears (from local cache) — replacing the live search results
- The search bar is still tappable but shows "Viewing cached results" as hint text
- Live search requires connectivity — an inline message explains this

**Appointment detail while offline:**

- Cached appointment data renders normally
- Actions that require connectivity (telehealth join, reschedule) are visually disabled with a "Requires connection" tooltip on tap

**Pending sync badge:**

- Any appointment with `sync_status = 'pending'` shows a small amber badge on its card: "Pending sync"
- The badge resolves to a green check on successful sync (animated, 200ms)

**Conflict bottom sheet design notes:**

- Appears immediately on conflict resolution, not on next app open
- The title is direct and factual: "That slot was just taken" — not evasive
- If alternative slots are shown, they render in the same SlotPicker component (compact variant, single-row scroll)
- Pre-filled form responses are preserved silently — the user doesn't need to re-fill anything to rebook

---

## Theming Implementation Notes

### Flutter

```dart
// theme/Veridian_theme.dart
ThemeData buildLightTheme() => ThemeData(
  colorScheme: ColorScheme.light(
    primary: Color(0xFF0D3B2E),
    secondary: Color(0xFF2ECC8F),
    surface: Color(0xFFF0FAF6),
    onPrimary: Color(0xFFE8F5F0),
    onSurface: Color(0xFF0D3B2E),
  ),
  scaffoldBackgroundColor: Color(0xFFF0FAF6),
  cardColor: Color(0xFFFFFFFF),
  textTheme: GoogleFonts.dmSansTextTheme().copyWith(
    displayLarge: GoogleFonts.outfit(
      fontSize: 20, fontWeight: FontWeight.w500, color: Color(0xFF0D3B2E)
    ),
  ),
  appBarTheme: AppBarTheme(
    backgroundColor: Color(0xFF0D3B2E),
    foregroundColor: Color(0xFFE8F5F0),
    elevation: 0,
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: Color(0xFF0D3B2E),
      foregroundColor: Color(0xFFE8F5F0),
      shape: StadiumBorder(),
      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 24),
    ),
  ),
  bottomNavigationBarTheme: BottomNavigationBarThemeData(
    backgroundColor: Color(0xFFFFFFFF),
    selectedItemColor: Color(0xFF0D3B2E),
    unselectedItemColor: Color(0xFFA3C4B8),
  ),
);

ThemeData buildDarkTheme() => ThemeData(
  colorScheme: ColorScheme.dark(
    primary: Color(0xFF2ECC8F),
    secondary: Color(0xFF0D3B2E),
    surface: Color(0xFF0D3B2E),
    onPrimary: Color(0xFF0D3B2E),
    onSurface: Color(0xFFE8F5F0),
  ),
  scaffoldBackgroundColor: Color(0xFF0D3B2E),
  cardColor: Color(0xFF163320),
  appBarTheme: AppBarTheme(
    backgroundColor: Color(0xFF0F2A22),
    foregroundColor: Color(0xFF2ECC8F),
    elevation: 0,
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: Color(0xFF2ECC8F),
      foregroundColor: Color(0xFF0D3B2E),
      shape: StadiumBorder(),
    ),
  ),
  bottomNavigationBarTheme: BottomNavigationBarThemeData(
    backgroundColor: Color(0xFF0F2A22),
    selectedItemColor: Color(0xFF2ECC8F),
    unselectedItemColor: Color(0xFF2ECC8F44),
  ),
);
```

### Next.js / Tailwind CSS v4

```js
// tailwind.config.ts
theme: {
  extend: {
    colors: {
      forest: {
        50:  '#F0FAF6',  // page bg, input bg
        100: '#E8F5F0',  // card fills, verified badge bg
        300: '#A3C4B8',  // muted text, borders
        500: '#2ECC8F',  // accent, active indicators
        600: '#1A5C46',  // secondary text
        700: '#0D3B2E',  // primary text, nav bg, primary buttons
        900: '#0F2A22',  // nav bar on web
      }
    },
    fontFamily: {
      display: ['Outfit', 'sans-serif'],
      sans: ['DM Sans', 'sans-serif'],
    }
  }
}
```

**Tailwind component classes in use:**

```html
<!-- Primary CTA button -->
<button
  class="bg-forest-700 text-forest-100 rounded-full px-6 py-2.5 text-sm font-medium
               hover:bg-forest-600 active:scale-95 transition-all"
>
  Book appointment
</button>

<!-- Verified badge -->
<span
  class="text-xs font-medium bg-forest-100 text-forest-700 px-2 py-0.5 rounded-md"
>
  ✓ GMDC
</span>

<!-- Doctor card -->
<div
  class="border border-forest-300/30 rounded-xl p-3 hover:border-forest-700
            transition-colors bg-white"
>
  ...
</div>

<!-- Nav bar -->
<nav class="bg-forest-700 h-11 flex items-center px-5 gap-5">
  <span class="text-forest-500 font-medium text-sm tracking-wide"
    >Veridian</span
  >
  ...
</nav>
```

---

## Motion & Animation Specification

| Interaction                              | Animation                       | Duration | Easing                               |
| ---------------------------------------- | ------------------------------- | -------- | ------------------------------------ |
| Screen push (mobile)                     | Slide from right                | 250ms    | `easeOutCubic`                       |
| Screen pop (mobile)                      | Slide to right                  | 200ms    | `easeInCubic`                        |
| Bottom sheet open                        | Slide up + fade in              | 300ms    | Spring (stiffness: 380, damping: 28) |
| Bottom sheet dismiss                     | Slide down + fade out           | 200ms    | `easeInCubic`                        |
| Conditional field appear                 | Height expand + opacity 0→1     | 250ms    | `easeOutCubic`                       |
| Conditional field disappear              | Height collapse + opacity 1→0   | 200ms    | `easeInCubic`                        |
| Booking confirmation checkmark           | Rive/Lottie once-play           | 800ms    | —                                    |
| Appointment card slide-in (post-confirm) | Translate Y 20px → 0 + opacity  | 300ms    | Spring                               |
| Slot pill selection (mobile)             | Scale 0.95 → 1.0                | 150ms    | Spring                               |
| Sync badge resolve (pending → synced)    | Colour transition amber → green | 200ms    | `easeOut`                            |
| Conflict modal appear                    | Backdrop fade + sheet spring    | 300ms    | Spring                               |
| Theme toggle (mobile)                    | Cross-fade system               | 400ms    | `easeInOut`                          |

All animations respect the system `prefers-reduced-motion` setting. When reduced motion is requested, all animations are replaced with instant transitions.

---

## Accessibility Requirements

### Web (WCAG 2.1 AA — mandatory per CI gate in Document 7)

- All interactive elements have visible focus rings (`outline: 2px solid #0D3B2E`, `outline-offset: 2px`)
- Colour contrast ratio ≥ 4.5:1 for all text. Forest green on white (#0D3B2E on #FFFFFF) = 11.2:1. Accent green on forest dark (#2ECC8F on #0D3B2E) = 5.1:1 — passes AA.
- All form fields have associated `<label>` elements
- All doctor avatar initials have `aria-label` with full name: `aria-label="Dr. Ama Owusu"`
- All images have `alt` attributes
- The booking flow uses `<fieldset>` + `<legend>` for each step's form group
- Status badges use `role="status"` for dynamic updates
- The slot picker calendar uses `role="grid"` with appropriate `aria-label` on each slot button

### Mobile (Flutter)

- All tappable elements have `Semantics` wrapper with descriptive label
- The pre-consultation form uses `Semantics(label: field.label, child: ...)` for all inputs
- Minimum touch target: 44×44 points (enforced via `SizedBox` wrapping where needed)
- Theme toggle accessible via Settings screen with visible label text

---

## Wireframe Annotation Legend

The rendered wireframes above use the following conventions:

| Element                         | Meaning                                                     |
| ------------------------------- | ----------------------------------------------------------- |
| Pill with "Today 2:30 PM"       | Next available slot (green tint = primary CTA)              |
| "⚠ May vary" amber text         | Slot `confidence_score < 0.6` — shown to patient            |
| "✓ GMDC" badge                  | Doctor `verification_status = 'verified'`                   |
| Amber "Pending payment" badge   | Appointment in `requested` status, payment not captured     |
| Amber "Pending sync" badge      | Appointment with `sync_status = 'pending'` in local DB      |
| Greyed-out slot in grid         | Slot `status = 'reserved'` or `'booked'`                    |
| Offline banner (amber strip)    | `ConnectivityState.offline`                                 |
| Toggle row in Profile/Settings  | Consent management (each toggle = one consent_record entry) |
| "Requires connection" on action | Operation cannot be queued (e.g., payment)                  |

---

## Files Produced

| File                       | Description                                                                                       |
| -------------------------- | ------------------------------------------------------------------------------------------------- |
| `Veridian-wireframes.md`   | This document — component specifications, design tokens, screen inventory, and all annotations    |
| Inline rendered wireframes | 10 mobile screens (patient + doctor, light + dark) and 4 web layouts rendered as interactive HTML |

---

## Level 2 Documents — Complete

All 10 Level 2 documents have been produced. The complete set:

| #         | Document                     | File                                                  | Lines             |
| --------- | ---------------------------- | ----------------------------------------------------- | ----------------- |
| 1         | Database Schema & ERD        | `Veridian_schema.sql` + `Veridian-database-schema.md` | 2,174             |
| 2         | API Contract (OpenAPI)       | `Veridian_openapi.yaml` + `Veridian-api-contract.md`  | 4,502             |
| 3         | State Machine Definitions    | `Veridian-state-machines.md`                          | 1,002             |
| 4         | Offline Sync Conflict Rules  | `Veridian-offline-sync.md`                            | 1,014             |
| 5         | Pre-Consultation Form Schema | `Veridian-form-schema.md`                             | 1,091             |
| 6         | Security Threat Model        | `Veridian-threat-model.md`                            | 786               |
| 7         | Test Strategy                | `Veridian-test-strategy.md`                           | 1,343             |
| 8         | Operational Runbooks         | `Veridian-runbooks.md`                                | 1,507             |
| 9         | Legal & Compliance (Ghana)   | `Veridian-legal-compliance.md`                        | 564               |
| 10        | UI/UX Wireframes             | `Veridian-wireframes.md`                              | this file         |
| —         | Master Implementation Plan   | `Veridian-implementation-plan.md`                     | 916               |
| **Total** |                              |                                                       | **~15,000 lines** |
