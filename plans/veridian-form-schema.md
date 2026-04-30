# Veridian — Document 5 of 10: Pre-Consultation Form Schema

**Project:** Veridian All-in-One Service Booking Platform  
**Version:** 1.0.0  
**Status:** Authoritative — all form rendering, validation, storage, and versioning behaviour derives from this document  
**Applies to:** Django API, Flutter mobile, Next.js web

---

## Purpose

The pre-consultation form is the structured questionnaire a patient fills out at Step 2 of the booking flow. It gives the doctor context before the appointment starts. Each doctor defines their own form template; the platform renders it dynamically from a JSON schema.

This document specifies:

1. The complete field type system (8 types, with all properties)
2. Conditional logic rules (show/hide fields based on other answers)
3. Validation rules (per-field and cross-field)
4. Template versioning (how schema changes affect existing appointments)
5. The rendering contract (how Flutter and Next.js must interpret the schema)
6. The response storage format (how answers are stored in the database)
7. The default platform template (used when a doctor has no custom template)

---

## Data Model Recap (from Document 1)

```sql
-- pre_consultation_form_templates
id                  UUID PK
doctor_profile_id   UUID FK → doctor_profiles
name                VARCHAR(200)
description         TEXT
fields              JSONB   -- array of field objects (schema defined in this document)
is_default          BOOLEAN -- only one default per doctor
is_active           BOOLEAN
version             SMALLINT  -- monotonically increasing; starts at 1

-- appointments
form_template_id    UUID FK → pre_consultation_form_templates (nullable)
pre_consultation_responses  JSONB  -- map of field_id → answer
```

**Key rule:** When a doctor updates their form template (via `PUT /doctors/me/form-templates/{id}`), a new version record is created. The old version is deactivated (`is_active = false`). Existing appointments retain a reference to the version that was active at booking time via `form_template_id`. The response JSONB is always interpreted against the template version it was submitted under.

---

## Field Type System

Every field in the `fields` JSONB array is an object conforming to the **BaseField** schema plus type-specific extensions.

### BaseField (all field types share these properties)

```typescript
interface BaseField {
  id: string; // UUID v4. Stable identifier across template versions.
  // MUST remain the same when editing a field's label/options.
  // Create a new UUID only for genuinely new fields.

  type: FieldType; // Discriminator — one of the 8 types below

  label: string; // Patient-facing question text. Max 500 chars.
  // Should be a complete sentence or clear question.
  // Example: "What is your main reason for visiting today?"

  required: boolean; // If true, form cannot be submitted without a valid answer.
  // Conditional fields: required only when visible.

  order: number; // Integer. Ascending. Controls render order.
  // Gaps allowed (e.g. 10, 20, 30) for easy reordering.

  placeholder?: string; // Hint text shown inside empty input. Max 200 chars.
  // Optional for all types.

  help_text?: string; // Secondary explanation below the field label.
  // Shown as small muted text. Max 300 chars.
  // Example: "Include the exact medication name and dosage."

  condition?: FieldCondition; // If present, field is hidden unless condition is met.
  // See Conditional Logic section.

  section?: string; // Optional grouping label. Fields with the same section
  // string are rendered under a shared section header.
  // Example: "Medications", "Symptoms", "Medical history"
}
```

---

### Field Types

#### TYPE 1: `text`

Single-line free text. Use for short answers: names, specific drug names, ID numbers.

```typescript
interface TextField extends BaseField {
  type: "text";
  min_length?: number; // Minimum character count. Default: 0.
  max_length?: number; // Maximum character count. Default: 500.
  pattern?: string; // Optional regex for format validation.
  // Example: "^[A-Z0-9-]+$" for prescription codes.
  pattern_error_message?: string; // User-facing message when pattern fails.
  // Example: "Please enter a valid prescription code."
  input_mode?: "text" | "numeric" | "tel" | "email";
  // Controls mobile keyboard type. Default: 'text'.
  // 'numeric' → number pad (but answer stored as string)
  // 'tel' → phone keyboard
}

// Stored answer type: string
// Example: "Paracetamol 500mg"
```

#### TYPE 2: `textarea`

Multi-line free text. Use for detailed descriptions: symptom narratives, medical history.

```typescript
interface TextareaField extends BaseField {
  type: "textarea";
  min_length?: number; // Default: 0.
  max_length?: number; // Default: 2000.
  rows?: number; // Hint for initial visible height. Default: 4.
  // Flutter: maps to maxLines. Web: maps to rows attr.
}

// Stored answer type: string
// Example: "I have had a persistent cough for 5 days, worse at night..."
```

#### TYPE 3: `select`

Single-choice from a predefined list. Use for categorical questions with a small, known set of options.

```typescript
interface SelectField extends BaseField {
  type: "select";
  options: SelectOption[]; // The choices. Min 2, max 20 options.
  allow_other?: boolean; // Default: false. If true, a free-text "Other:" input
  // appears when user selects the last option (which must
  // be labelled "Other" or "Other (please specify)").
}

interface SelectOption {
  value: string; // Stored in JSONB. Snake_case. Max 100 chars.
  // Example: "less_than_24_hours"
  label: string; // Displayed to patient. Max 200 chars.
  // Example: "Less than 24 hours"
  is_alert?: boolean; // Default: false. If true, selecting this option adds
  // a visual alert indicator on the doctor's appointment
  // view. Use for clinically significant choices.
  // Example: "chest_pain", "difficulty_breathing"
}

// Stored answer type: string (the value field of the chosen option)
// If allow_other selected: string "other::<patient_text>"
// Example: "less_than_24_hours"
// Example (other): "other::Approximately 36 hours"
```

#### TYPE 4: `multi_select`

Multiple-choice from a predefined list. Use for "select all that apply" questions.

```typescript
interface MultiSelectField extends BaseField {
  type: "multi_select";
  options: SelectOption[]; // Same structure as select. Min 2, max 30 options.
  min_selections?: number; // Minimum number of choices required. Default: 0.
  max_selections?: number; // Maximum number of choices allowed. Default: unlimited.
  allow_other?: boolean; // Default: false. Same behaviour as select.
}

// Stored answer type: string[] (array of selected values)
// Example: ["headache", "fever", "fatigue"]
// If allow_other included: ["headache", "other::Jaw pain"]
```

#### TYPE 5: `boolean`

Yes/No question. Rendered as a toggle, switch, or pair of radio buttons.

```typescript
interface BooleanField extends BaseField {
  type: "boolean";
  true_label?: string; // Label for the "yes" option. Default: "Yes".
  false_label?: string; // Label for the "no" option. Default: "No".
  default_value?: boolean; // Pre-selected value. Default: null (unselected).
  // Use sparingly — pre-selection can bias responses.
}

// Stored answer type: boolean
// Example: true
// NOTE: null is NOT a valid stored value. Required booleans must be explicitly answered.
```

#### TYPE 6: `number`

Numeric input. Use for quantitative values: age, number of days, dosage amounts.

```typescript
interface NumberField extends BaseField {
  type: "number";
  min?: number; // Minimum allowed value (inclusive).
  max?: number; // Maximum allowed value (inclusive).
  step?: number; // Increment step. Default: 1.
  // Use 0.1 for decimal values (e.g., temperature: 36.5).
  unit?: string; // Unit label displayed next to input. Max 20 chars.
  // Example: "days", "kg", "°C", "mg"
  decimal_places?: number; // Max decimal places for validation. Default: 0.
}

// Stored answer type: number
// Example: 5
// Example (decimal): 37.2
```

#### TYPE 7: `date`

Date picker. Use for event dates: last menstrual period, date of injury, last vaccination.

```typescript
interface DateField extends BaseField {
  type: "date";
  min_date?: string; // ISO 8601 date string OR relative expression.
  // Relative: "-30d" (30 days ago), "-1y" (1 year ago)
  // Absolute: "2020-01-01"
  max_date?: string; // ISO 8601 date string OR relative expression.
  // Relative: "today", "+30d" (30 days from now)
  // Default max: "today" (cannot select future dates
  //              for past-event questions)
  display_format?: string; // Display format for the picker. Default: "DD MMM YYYY".
  // Example: "DD/MM/YYYY"
}

// Stored answer type: string (ISO 8601 date: YYYY-MM-DD)
// Example: "2025-06-10"
```

#### TYPE 8: `file`

File upload. Use for documents the patient should attach: lab results, prescriptions, referral letters.

```typescript
interface FileField extends BaseField {
  type: "file";
  allowed_mime_types: string[]; // Required. Restrict file types for security.
  // Recommended sets:
  // Images: ["image/jpeg", "image/png", "image/webp"]
  // Documents: ["application/pdf"]
  // Both: ["image/jpeg", "image/png", "application/pdf"]
  max_file_size_mb?: number; // Maximum file size in megabytes. Default: 10. Max: 25.
  max_files?: number; // Maximum number of files. Default: 1. Max: 5.
  instructions?: string; // Additional guidance for the upload.
  // Example: "Please upload a clear photo or scan of
  //           your most recent blood test results."
}

// Stored answer type: string[] (array of Supabase Storage keys)
// Files are uploaded directly to Supabase Storage before form submission.
// Uploads first land in the `quarantine` bucket; a ClamAV + python-magic
// worker scans each file and, on a clean verdict, moves it to
// `health-documents` and sets `documents.scan_status='clean'`.
// The form submission sends storage keys, not file content.
// The form can only be submitted once every referenced document has
// scan_status='clean' — the API rejects submission with 409 otherwise.
// Storage bucket: 'health-documents' (private, signed URL access gated on scan_status)
// Example: ["health-documents/patient-uuid/appt-uuid/lab-result-1.pdf"]
```

---

## Conditional Logic

Fields can be shown or hidden based on the answer to another field in the same form. This is controlled by the `condition` property on the dependent field.

### FieldCondition Schema

```typescript
interface FieldCondition {
  field_id: string; // UUID of the field this condition depends on.
  // Must be a field with order LOWER than this field.
  // Forward references are NOT allowed.

  operator: ConditionOperator; // How to compare the answer to the value.

  value: ConditionValue; // The value to compare against.
  // Type must be compatible with the referenced field type.

  // Optional: chain multiple conditions with AND logic
  // (OR logic: create separate conditional fields with separate conditions)
  and?: FieldCondition; // Secondary condition that must also be true.
}

type ConditionOperator =
  | "equals" // answer === value  (works for: text, select, boolean, number, date)
  | "not_equals" // answer !== value
  | "contains" // answer includes value (works for: text, textarea, multi_select)
  | "not_contains" // answer does not include value
  | "greater_than" // answer > value  (works for: number, date)
  | "less_than" // answer < value
  | "is_answered" // field has any non-null, non-empty answer (ignores value)
  | "is_not_answered"; // field has no answer or is empty

type ConditionValue = string | number | boolean | string[];
```

### Condition Evaluation Rules

1. **Visibility:** A field with a `condition` is hidden by default. It becomes visible only when the condition evaluates to `true`.

2. **Required enforcement:** A hidden field is NEVER required, regardless of its `required` property. Required is only enforced when the field is visible.

3. **Value clearing:** When a field becomes hidden due to a condition change, its current value is cleared from the in-memory form state. Cleared values are NOT sent in the submission payload. This prevents stale conditional answers from reaching the database.

4. **Cascading conditions:** If Field B is conditional on Field A, and Field C is conditional on Field B: when Field A's answer hides Field B, Field C is also hidden and cleared — even if Field C's condition on Field B would evaluate to true. Evaluate conditions depth-first from the top.

5. **Circular references:** A field cannot have a `condition.field_id` that is equal to its own `id`, or that creates a reference cycle. The Django API validates this on template save and returns 400 if a cycle is detected.

6. **Order constraint:** `condition.field_id` must reference a field with a lower `order` value. This ensures the referenced field is always rendered (and answered) before the dependent field. The Django API enforces this.

### Condition Examples

```json
// Example 1: Show "Which condition?" only if "Do you have a chronic condition?" = true
{
  "id": "uuid-chronic-condition-text",
  "type": "text",
  "label": "Which chronic condition?",
  "required": true,
  "order": 30,
  "condition": {
    "field_id": "uuid-has-chronic-condition",
    "operator": "equals",
    "value": true
  }
}

// Example 2: Show medication details only if patient takes medications
{
  "id": "uuid-medication-details",
  "type": "textarea",
  "label": "Please list your current medications and dosages",
  "required": true,
  "order": 50,
  "condition": {
    "field_id": "uuid-takes-medication",
    "operator": "equals",
    "value": true
  }
}

// Example 3: Show severity scale only if chest pain is selected
{
  "id": "uuid-chest-pain-severity",
  "type": "number",
  "label": "On a scale of 1–10, how severe is your chest pain?",
  "required": true,
  "min": 1,
  "max": 10,
  "order": 40,
  "condition": {
    "field_id": "uuid-symptoms",
    "operator": "contains",
    "value": "chest_pain"
  }
}

// Example 4: Compound condition (AND) — show extra field only if pregnant AND in first trimester
{
  "id": "uuid-prenatal-vitamins",
  "type": "boolean",
  "label": "Are you currently taking prenatal vitamins?",
  "required": false,
  "order": 60,
  "condition": {
    "field_id": "uuid-is-pregnant",
    "operator": "equals",
    "value": true,
    "and": {
      "field_id": "uuid-trimester",
      "operator": "equals",
      "value": "first"
    }
  }
}
```

---

## Validation Rules

### Per-Field Validation

Validation is enforced identically on both the client (Flutter/Next.js) and the server (Django serializer). Client-side validation provides instant feedback; server-side validation is the enforcement layer.

| Field type     | Validated properties                                                  | Error message pattern                                                                                                      |
| -------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `text`         | `required`, `min_length`, `max_length`, `pattern`                     | "This field is required." / "Minimum {n} characters." / "Maximum {n} characters." / `pattern_error_message`                |
| `textarea`     | `required`, `min_length`, `max_length`                                | Same as text                                                                                                               |
| `select`       | `required`, value must be in options                                  | "Please select an option."                                                                                                 |
| `multi_select` | `required`, `min_selections`, `max_selections`, all values in options | "Please select at least {n} option(s)." / "You can select at most {n} option(s)."                                          |
| `boolean`      | `required` (must be explicitly true or false, not null)               | "Please answer yes or no."                                                                                                 |
| `number`       | `required`, `min`, `max`, `decimal_places`                            | "Please enter a number." / "Must be at least {min}." / "Must be at most {max}." / "Maximum {n} decimal places."            |
| `date`         | `required`, `min_date`, `max_date`                                    | "Please select a date." / "Date must be on or after {min}." / "Date must be on or before {max}."                           |
| `file`         | `required`, `allowed_mime_types`, `max_file_size_mb`, `max_files`     | "Please upload a file." / "Only {types} files are allowed." / "File must be under {n}MB." / "Maximum {n} file(s) allowed." |

### Cross-Field Validation

The Django API validates the entire submission after per-field validation passes:

1. **No extra fields:** The submission payload must not contain field IDs not present in the template. Extra fields are stripped silently (not rejected) to handle edge cases where the template version changed between form render and submission.

2. **No answers for hidden fields:** If the submission contains an answer for a field whose condition evaluates to `false` given the other answers in the submission, the API strips that field's answer silently before storing. This handles the case where a client fails to clear a conditional field's value.

3. **File keys exist and are clean:** All storage keys in file field answers must exist in Supabase Storage and belong to the current patient. The API validates this via a Supabase Storage metadata check before storing. Additionally, every referenced storage key must resolve to a `documents` row with `scan_status = 'clean'` — if any file is still `pending`, submission is rejected with HTTP 409 (`files_still_scanning`) and the client polls; if any file is `infected` or `error`, submission is rejected with 422 (`file_rejected`) and the offending field is flagged so the patient can re-upload.

4. **Template version active:** The `form_template_id` referenced in the booking request must have `is_active = true`. If the doctor replaced their template between when the patient loaded the form and when they submitted, the API returns 409 with `FORM_TEMPLATE_VERSION_CHANGED`, including the new template in the response so the client can re-render.

### Django Serializer Pattern

```python
# appointments/serializers.py

class PreConsultationResponsesValidator:
    def __init__(self, template: PreConsultationFormTemplate):
        self.template = template
        self.fields = {f['id']: f for f in template.fields}

    def validate(self, responses: dict) -> dict:
        errors = {}
        cleaned = {}

        # Determine which fields are visible given current responses
        visible_fields = self._resolve_visible_fields(responses)

        for field in self.fields.values():
            field_id = field['id']
            is_visible = field_id in visible_fields
            answer = responses.get(field_id)

            if not is_visible:
                # Strip hidden field answers silently
                continue

            if field['required'] and (answer is None or answer == '' or answer == []):
                errors[field_id] = [f"This field is required."]
                continue

            if answer is not None:
                field_errors = self._validate_field(field, answer)
                if field_errors:
                    errors[field_id] = field_errors
                else:
                    cleaned[field_id] = answer

        if errors:
            raise serializers.ValidationError(errors)

        return cleaned

    def _resolve_visible_fields(self, responses: dict) -> set:
        """Topological sort + condition evaluation. Returns set of visible field IDs."""
        visible = set()
        # Process fields in order (order field guarantees forward-only references)
        for field in sorted(self.fields.values(), key=lambda f: f['order']):
            if 'condition' not in field:
                visible.add(field['id'])
            elif self._evaluate_condition(field['condition'], responses, visible):
                visible.add(field['id'])
        return visible

    def _evaluate_condition(self, condition: dict, responses: dict, visible: set) -> bool:
        field_id = condition['field_id']
        if field_id not in visible:
            return False  # Referenced field is itself hidden — dependent is also hidden

        answer = responses.get(field_id)
        operator = condition['operator']
        value = condition['value']

        result = self._apply_operator(operator, answer, value)

        if result and 'and' in condition:
            result = self._evaluate_condition(condition['and'], responses, visible)

        return result

    def _apply_operator(self, operator: str, answer, value) -> bool:
        match operator:
            case 'equals':        return answer == value
            case 'not_equals':    return answer != value
            case 'contains':
                if isinstance(answer, list): return value in answer
                if isinstance(answer, str):  return value in answer
                return False
            case 'not_contains':
                if isinstance(answer, list): return value not in answer
                if isinstance(answer, str):  return value not in answer
                return True
            case 'greater_than':  return answer is not None and answer > value
            case 'less_than':     return answer is not None and answer < value
            case 'is_answered':   return answer is not None and answer != '' and answer != []
            case 'is_not_answered': return answer is None or answer == '' or answer == []
            case _:               return False
```

---

## Template Versioning

### Version Lifecycle

```
Doctor creates template → version=1, is_active=true
                                │
Doctor edits template (PUT) → Old record: is_active=false
                               New record: version=2, is_active=true
                                │
Existing appointments → Still reference version=1 record
New appointments      → Reference version=2 record
```

### What constitutes a "breaking change"?

Not all edits require a new version. The API distinguishes:

**Non-breaking changes** (update in-place, same version):

- Editing `label`, `help_text`, `placeholder`, `description`, `name` on existing fields
- Changing `order` of existing fields
- Adding `section` labels to existing fields
- Changing `required: false` to `required: false` (no semantic change)
- Changing `max_length` to a higher value
- Adding new options to a `select` or `multi_select` field

**Breaking changes** (create new version):

- Adding a new field with `required: true`
- Removing a field (removing its `id` from the array)
- Changing a field's `type`
- Changing a field's `id` (treat this as remove + add)
- Changing `required: false` to `required: true` on an existing field
- Adding or changing a `condition` on an existing field
- Removing options from a `select` or `multi_select` field that may have existing answers

The Django API applies this classification automatically on `PUT /doctors/me/form-templates/{id}`:

```python
def classify_template_change(old_fields: list, new_fields: list) -> str:
    old_by_id = {f['id']: f for f in old_fields}
    new_by_id = {f['id']: f for f in new_fields}

    # Check for removed fields
    for old_id in old_by_id:
        if old_id not in new_by_id:
            return 'breaking'

    # Check for new required fields or type/condition changes
    for field_id, new_field in new_by_id.items():
        if field_id not in old_by_id:
            if new_field.get('required', False):
                return 'breaking'
        else:
            old_field = old_by_id[field_id]
            if (old_field['type'] != new_field['type'] or
                old_field.get('condition') != new_field.get('condition') or
                (not old_field.get('required') and new_field.get('required'))):
                return 'breaking'

    return 'non_breaking'
```

### Version Conflict at Booking Time

If a patient loads the pre-consultation form and the doctor updates their template before the patient submits:

**Server response:**

```json
HTTP 409
{
  "error": {
    "code": "FORM_TEMPLATE_VERSION_CHANGED",
    "message": "The form has been updated. Please review and resubmit.",
    "new_template": {
      "id": "uuid",
      "version": 3,
      "fields": [ ... ]
    }
  }
}
```

**Client behaviour:**

- Flutter: Show a bottom sheet: "The doctor updated their pre-consultation questions. Please review the updated form." Re-render form with new template. Preserve answers for fields whose `id` exists in both old and new template.
- Next.js: Show a toast notification and re-render the form section with the new template. Same answer-preservation logic.

**Answer preservation on version change:**

```typescript
function preserveAnswers(
  oldResponses: Record<string, unknown>,
  oldFields: Field[],
  newFields: Field[],
): Record<string, unknown> {
  const newFieldIds = new Set(newFields.map((f) => f.id));
  const preserved: Record<string, unknown> = {};

  for (const [fieldId, answer] of Object.entries(oldResponses)) {
    if (!newFieldIds.has(fieldId)) continue;

    const oldField = oldFields.find((f) => f.id === fieldId);
    const newField = newFields.find((f) => f.id === fieldId);

    // Only preserve if field type hasn't changed
    if (oldField?.type === newField?.type) {
      preserved[fieldId] = answer;
    }
  }

  return preserved;
}
```

---

## Response Storage Format

Answers are stored in `appointments.pre_consultation_responses` as a flat JSONB object. Keys are field UUIDs; values are typed answers.

### Complete Example

```json
{
  "a1b2c3d4-0001-0001-0001-000000000001": "Persistent cough and mild fever",
  "a1b2c3d4-0001-0001-0001-000000000002": "four_to_seven_days",
  "a1b2c3d4-0001-0001-0001-000000000003": ["cough", "fever", "fatigue"],
  "a1b2c3d4-0001-0001-0001-000000000004": true,
  "a1b2c3d4-0001-0001-0001-000000000005": "Paracetamol 500mg twice daily",
  "a1b2c3d4-0001-0001-0001-000000000006": 37.8,
  "a1b2c3d4-0001-0001-0001-000000000007": "2025-06-10",
  "a1b2c3d4-0001-0001-0001-000000000008": [
    "health-documents/patient-uuid/appt-uuid/lab-result.pdf"
  ]
}
```

Note: Fields that were hidden (condition evaluated to false) or left empty by the patient are simply absent from the object. The doctor's view never shows keys for fields that weren't answered.

### Doctor View Format

When the doctor views an appointment, the API transforms the raw `pre_consultation_responses` JSONB into a human-readable structure:

```json
{
  "sections": [
    {
      "title": "Reason for visit",
      "fields": [
        {
          "label": "What is your main reason for visiting today?",
          "type": "textarea",
          "answer": "Persistent cough and mild fever",
          "answer_display": "Persistent cough and mild fever",
          "is_alert": false
        },
        {
          "label": "How long have you had these symptoms?",
          "type": "select",
          "answer": "four_to_seven_days",
          "answer_display": "4–7 days",
          "is_alert": false
        }
      ]
    },
    {
      "title": "Symptoms",
      "fields": [
        {
          "label": "Which of the following do you currently experience?",
          "type": "multi_select",
          "answer": ["cough", "fever", "fatigue"],
          "answer_display": "Cough, Fever, Fatigue",
          "is_alert": false
        }
      ]
    }
  ],
  "alerts": [],
  "unanswered_required_fields": []
}
```

The `answer_display` field is generated by the API by looking up option labels for `select`/`multi_select` types, formatting dates, and constructing file download URLs for file fields.

The `alerts` array contains field labels where the selected option had `is_alert: true`. This is displayed prominently at the top of the doctor's pre-consultation view with a visual warning indicator.

---

## Default Platform Template

When a doctor has no active custom template, the platform applies this default template. It covers the most common primary care consultation questions.

```json
{
  "name": "Standard Pre-Consultation",
  "description": "Veridian default pre-consultation questionnaire",
  "version": 1,
  "fields": [
    {
      "id": "platform-default-0001",
      "type": "textarea",
      "label": "What is your main reason for visiting today?",
      "placeholder": "Describe your symptoms or concern in as much detail as possible.",
      "required": true,
      "order": 10,
      "section": "Reason for visit",
      "min_length": 10,
      "max_length": 1000
    },
    {
      "id": "platform-default-0002",
      "type": "select",
      "label": "How long have you had this concern?",
      "required": true,
      "order": 20,
      "section": "Reason for visit",
      "options": [
        { "value": "less_than_24h", "label": "Less than 24 hours" },
        { "value": "one_to_three_days", "label": "1–3 days" },
        { "value": "four_to_seven_days", "label": "4–7 days" },
        { "value": "one_to_four_weeks", "label": "1–4 weeks" },
        { "value": "more_than_a_month", "label": "More than a month" }
      ]
    },
    {
      "id": "platform-default-0003",
      "type": "boolean",
      "label": "Is this a follow-up for a previous consultation?",
      "required": true,
      "order": 30,
      "section": "Reason for visit"
    },
    {
      "id": "platform-default-0004",
      "type": "textarea",
      "label": "What was the previous consultation for?",
      "required": true,
      "order": 40,
      "section": "Reason for visit",
      "max_length": 500,
      "condition": {
        "field_id": "platform-default-0003",
        "operator": "equals",
        "value": true
      }
    },
    {
      "id": "platform-default-0005",
      "type": "multi_select",
      "label": "Do you currently experience any of the following?",
      "required": false,
      "order": 50,
      "section": "Symptoms",
      "options": [
        { "value": "fever", "label": "Fever or chills" },
        { "value": "cough", "label": "Cough" },
        {
          "value": "shortness_of_breath",
          "label": "Shortness of breath",
          "is_alert": true
        },
        { "value": "chest_pain", "label": "Chest pain", "is_alert": true },
        { "value": "headache", "label": "Headache" },
        { "value": "fatigue", "label": "Fatigue or weakness" },
        { "value": "nausea", "label": "Nausea or vomiting" },
        { "value": "diarrhoea", "label": "Diarrhoea" },
        { "value": "rash", "label": "Rash or skin changes" },
        { "value": "joint_pain", "label": "Joint or muscle pain" },
        {
          "value": "dizziness",
          "label": "Dizziness or fainting",
          "is_alert": true
        },
        { "value": "none", "label": "None of the above" }
      ]
    },
    {
      "id": "platform-default-0006",
      "type": "boolean",
      "label": "Are you currently taking any medications?",
      "required": true,
      "order": 60,
      "section": "Medications"
    },
    {
      "id": "platform-default-0007",
      "type": "textarea",
      "label": "Please list your current medications, including dosage and frequency.",
      "placeholder": "Example: Metformin 500mg twice daily, Lisinopril 10mg once daily",
      "required": true,
      "order": 70,
      "section": "Medications",
      "max_length": 1000,
      "condition": {
        "field_id": "platform-default-0006",
        "operator": "equals",
        "value": true
      }
    },
    {
      "id": "platform-default-0008",
      "type": "boolean",
      "label": "Do you have any known allergies (medications, foods, or other)?",
      "required": true,
      "order": 80,
      "section": "Allergies"
    },
    {
      "id": "platform-default-0009",
      "type": "textarea",
      "label": "Please describe your allergies and your reactions to them.",
      "required": true,
      "order": 90,
      "section": "Allergies",
      "max_length": 500,
      "condition": {
        "field_id": "platform-default-0008",
        "operator": "equals",
        "value": true
      }
    },
    {
      "id": "platform-default-0010",
      "type": "file",
      "label": "Do you have any relevant documents to share? (Optional)",
      "help_text": "Upload lab results, previous prescriptions, or referral letters. PDF or image files only.",
      "required": false,
      "order": 100,
      "section": "Documents",
      "allowed_mime_types": ["image/jpeg", "image/png", "application/pdf"],
      "max_file_size_mb": 10,
      "max_files": 3,
      "instructions": "Clear photos of physical documents are acceptable."
    }
  ]
}
```

---

## Rendering Contract

### Flutter Rendering

The Flutter form renderer is a `StatefulWidget` called `PreConsultationFormRenderer`. It receives the template fields and manages form state in a local `Map<String, dynamic>` controlled by `useState` / `StateProvider`.

```dart
// forms/pre_consultation_form_renderer.dart

class PreConsultationFormRenderer extends ConsumerStatefulWidget {
  final List<FormField> fields;
  final Map<String, dynamic>? initialResponses; // For version-change preservation
  final void Function(Map<String, dynamic> responses) onSubmit;
  final bool readOnly; // True when doctor views completed form

  const PreConsultationFormRenderer({...});
}

class _State extends ConsumerState<PreConsultationFormRenderer> {
  late Map<String, dynamic> _responses;
  late Map<String, bool> _fieldVisibility;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _responses = Map.from(widget.initialResponses ?? {});
    _recomputeVisibility();
  }

  void _onFieldChanged(String fieldId, dynamic value) {
    setState(() {
      _responses[fieldId] = value;
      _recomputeVisibility();
      // Clear hidden fields
      for (final field in widget.fields) {
        if (!_fieldVisibility[field.id]!) {
          _responses.remove(field.id);
        }
      }
    });
  }

  void _recomputeVisibility() {
    _fieldVisibility = {};
    for (final field in widget.fields..sort((a, b) => a.order.compareTo(b.order))) {
      if (field.condition == null) {
        _fieldVisibility[field.id] = true;
      } else {
        _fieldVisibility[field.id] = _evaluateCondition(
          field.condition!,
          _responses,
          _fieldVisibility,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sortedFields = widget.fields..sort((a, b) => a.order.compareTo(b.order));
    final sections = _groupBySection(sortedFields);

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final section in sections) ...[
            if (section.title != null)
              SectionHeader(title: section.title!),
            for (final field in section.fields)
              if (_fieldVisibility[field.id] == true)
                AnimatedFieldWrapper(
                  key: ValueKey(field.id),
                  child: _buildField(field),
                ),
          ],
          SubmitButton(
            onPressed: _handleSubmit,
            label: 'Continue to review',
          ),
        ],
      ),
    );
  }

  Widget _buildField(FormField field) => switch (field.type) {
    FieldType.text       => TextFormFieldWidget(field: field, onChanged: _onFieldChanged),
    FieldType.textarea   => TextareaFormFieldWidget(field: field, onChanged: _onFieldChanged),
    FieldType.select     => SelectFormFieldWidget(field: field, onChanged: _onFieldChanged),
    FieldType.multiSelect=> MultiSelectFormFieldWidget(field: field, onChanged: _onFieldChanged),
    FieldType.boolean    => BooleanFormFieldWidget(field: field, onChanged: _onFieldChanged),
    FieldType.number     => NumberFormFieldWidget(field: field, onChanged: _onFieldChanged),
    FieldType.date       => DateFormFieldWidget(field: field, onChanged: _onFieldChanged),
    FieldType.file       => FileUploadFormFieldWidget(field: field, onChanged: _onFieldChanged),
  };

  void _handleSubmit() {
    if (!_formKey.currentState!.validate()) return;
    // Strip hidden fields one final time before submitting
    final cleaned = Map.fromEntries(
      _responses.entries.where((e) => _fieldVisibility[e.key] == true),
    );
    widget.onSubmit(cleaned);
  }
}
```

**Animations:** Field appearance/disappearance (conditional logic) uses `AnimatedSize` wrapping `AnimatedOpacity` — fields slide in/out smoothly over 250ms. This makes conditional branching feel natural rather than jarring.

**Field widgets — key implementation notes:**

- `SelectFormFieldWidget`: Rendered as a scrollable bottom sheet on mobile (never a dropdown in a scrolling form — too easy to accidentally change). Web uses a standard `<select>`.
- `MultiSelectFormFieldWidget`: Rendered as a list of checkboxes in a contained card. Tapping opens a full-screen selection sheet on mobile.
- `FileUploadFormFieldWidget`: Uploads to Supabase Storage directly from the client before form submission. Shows upload progress per file. Validates MIME type client-side before upload.
- `DateFormFieldWidget`: Uses `showDatePicker` with locale set to patient's `preferred_language`. Evaluates `min_date`/`max_date` relative expressions at render time.

### Next.js Rendering

The Next.js form renderer is a `PreConsultationForm` React component that uses `react-hook-form` for form state and validation.

```tsx
// components/booking/PreConsultationForm.tsx

export function PreConsultationForm({
  fields,
  initialResponses,
  onSubmit,
  readOnly = false,
}: PreConsultationFormProps) {
  const {
    register,
    control,
    watch,
    handleSubmit,
    formState: { errors },
  } = useForm<Record<string, unknown>>({
    defaultValues: initialResponses ?? {},
  });

  const allValues = watch();

  // Compute field visibility reactively
  const fieldVisibility = useMemo(
    () => resolveFieldVisibility(fields, allValues),
    [fields, allValues],
  );

  const groupedFields = useMemo(
    () => groupFieldsBySection(fields.filter((f) => fieldVisibility[f.id])),
    [fields, fieldVisibility],
  );

  const handleValidatedSubmit = (data: Record<string, unknown>) => {
    // Strip answers for hidden fields
    const cleaned = Object.fromEntries(
      Object.entries(data).filter(([key]) => fieldVisibility[key]),
    );
    onSubmit(cleaned);
  };

  return (
    <form onSubmit={handleSubmit(handleValidatedSubmit)} className="space-y-8">
      {groupedFields.map((section) => (
        <fieldset key={section.title ?? "default"} className="space-y-4">
          {section.title && (
            <legend className="text-sm font-medium text-forest-700 uppercase tracking-wide">
              {section.title}
            </legend>
          )}
          {section.fields.map((field) => (
            <div key={field.id} className="transition-all duration-200">
              <FieldRenderer
                field={field}
                register={register}
                control={control}
                error={errors[field.id]}
                readOnly={readOnly}
              />
            </div>
          ))}
        </fieldset>
      ))}
      {!readOnly && (
        <Button type="submit" variant="primary" className="w-full">
          Continue to review
        </Button>
      )}
    </form>
  );
}
```

**shadcn/ui component mapping:**

| Field type     | shadcn/ui component                                                          |
| -------------- | ---------------------------------------------------------------------------- |
| `text`         | `Input`                                                                      |
| `textarea`     | `Textarea`                                                                   |
| `select`       | `Select` (shadcn Select with `SelectTrigger`, `SelectContent`, `SelectItem`) |
| `multi_select` | Custom: `Command` + `CommandInput` + checkboxes in popover                   |
| `boolean`      | `RadioGroup` with Yes/No options                                             |
| `number`       | `Input` with `type="number"`                                                 |
| `date`         | `Popover` + `Calendar` (shadcn Calendar component)                           |
| `file`         | Custom `FileUpload` built on `Input type="file"` + Supabase Storage client   |

---

## Template Builder UI (Doctor-Facing)

The doctor's template builder in the web dashboard allows creating and editing form templates through a visual drag-and-drop interface. It is a React component that produces and consumes the fields JSON schema defined in this document.

### Builder State

```typescript
interface TemplateBuilderState {
  name: string;
  description: string;
  fields: Field[];
  isDirty: boolean; // True when unsaved changes exist
  changeType: "non_breaking" | "breaking" | null; // Computed from diff
}
```

### Builder Behaviour Rules

1. **Add field** → generates a new UUID for the field's `id`. Appends to end with `order = max_order + 10`.
2. **Drag to reorder** → updates `order` values to reflect new sequence. IDs are preserved.
3. **Delete field** → marks as deleted in builder state. On save, triggers breaking-change classification if the field had `required: true` or was referenced by another field's condition.
4. **Edit field label** → non-breaking. Updates in-place.
5. **Change field type** → breaking. Warns doctor: "Changing a field's type creates a new form version. Existing bookings will keep the old form."
6. **Add condition** → breaking if the field was previously unconditional and `required: true`.
7. **Save** → calls PUT endpoint. If breaking, shows confirmation dialog: "This will create a new version of your form. Patients currently filling out the form will see a notification to review the updated questions."

---

## Security Considerations

### File Upload Security

1. **MIME type validation is triple-enforced:** Client validates declared MIME type before upload; Supabase Storage `allowed_mime_types` policy validates at storage level; the malware scan worker re-validates using `python-magic` content sniffing (rejects a file whose sniffed type does not match its declared type). The file field's `allowed_mime_types` array must be a subset of `["image/jpeg", "image/png", "image/webp", "application/pdf"]`. No executable types ever allowed.

2. **File ownership:** Files uploaded for pre-consultation forms are stored in the `health-documents` bucket under the path `{patient_id}/{appointment_id}/{filename}`. RLS policies on the storage bucket ensure only the owning patient and the appointment's doctor can access these files.

3. **Malware scan gate (see threat model T-6):** All uploads land in the `quarantine` bucket with `documents.scan_status = 'pending'`. A Celery worker runs ClamAV (`clamdscan --stream`) plus `python-magic` content sniffing plus `qpdf --linearize` JavaScript stripping for PDFs. On `clean`, the object is moved to `health-documents` and `scan_status` is updated. The signed-URL endpoint **refuses to issue a URL unless `scan_status = 'clean'`** — a patient or doctor requesting a URL for a pending or infected document receives HTTP 409 with a "still processing" or "file rejected" message. Infected files trigger a SOC alert (`security_events.malware_detected`) and remain in quarantine for forensic review.

4. **Signed URLs are `Content-Disposition: attachment`:** File answers are stored as storage keys, not public URLs. The API generates short-lived signed URLs (1 hour) when the doctor views the pre-consultation responses. URLs carry `response-content-disposition=attachment; filename="..."` so browsers download rather than render (defence against HTML/SVG/PDF active-content attacks).

5. **Max file size** is enforced at the storage bucket level (`25MB` hard limit) and at the field level (`max_file_size_mb`, default `10MB`).

### Injection Prevention

1. All text answers are stored as-is in JSONB (no HTML rendering). The doctor's view renders answers as plain text using `dangerouslySetInnerHTML` is never used — values are always rendered through React's text content system or Flutter's `Text()` widget.

2. The `pattern` property on `text` fields is validated server-side using Python's `re` module with a timeout guard to prevent ReDoS attacks. Patterns that take more than 100ms to evaluate are rejected at template save time.

---

\*Next document: **Document 6 of 10 — Security Threat Model\***  
_Every attack surface, threat actor, specific attack scenario, and the layered defence for each — for a healthcare booking platform handling medical records and payments in Ghana._
