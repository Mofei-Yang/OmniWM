#ifndef OMNIWM_KERNELS_H
#define OMNIWM_KERNELS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    OMNIWM_KERNELS_STATUS_OK = 0,
    OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT = 1,
    OMNIWM_KERNELS_STATUS_ALLOCATION_FAILED = 2,
    OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL = 3,
};

enum {
    OMNIWM_CENTER_FOCUSED_COLUMN_NEVER = 0,
    OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS = 1,
    OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW = 2,
};

enum {
    OMNIWM_DWINDLE_NODE_KIND_SPLIT = 0,
    OMNIWM_DWINDLE_NODE_KIND_LEAF = 1,
};

enum {
    OMNIWM_DWINDLE_ORIENTATION_HORIZONTAL = 0,
    OMNIWM_DWINDLE_ORIENTATION_VERTICAL = 1,
};

enum {
    OMNIWM_NIRI_ORIENTATION_HORIZONTAL = 0,
    OMNIWM_NIRI_ORIENTATION_VERTICAL = 1,
};

enum {
    OMNIWM_NIRI_WINDOW_SIZING_NORMAL = 0,
    OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN = 1,
};

enum {
    OMNIWM_NIRI_HIDDEN_EDGE_NONE = 0,
    OMNIWM_NIRI_HIDDEN_EDGE_MINIMUM = 1,
    OMNIWM_NIRI_HIDDEN_EDGE_MAXIMUM = 2,
};

typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    double fixed_value;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
} omniwm_axis_input;

typedef struct {
    double value;
    uint8_t was_constrained;
} omniwm_axis_output;

typedef struct {
    int32_t root_index;
    double screen_x;
    double screen_y;
    double screen_width;
    double screen_height;
    double inner_gap;
    double outer_gap_top;
    double outer_gap_bottom;
    double outer_gap_left;
    double outer_gap_right;
    double single_window_aspect_width;
    double single_window_aspect_height;
    double single_window_aspect_tolerance;
    double minimum_dimension;
    double gap_sticks_tolerance;
    double split_ratio_min;
    double split_ratio_max;
    double split_fraction_divisor;
    double split_fraction_min;
    double split_fraction_max;
} omniwm_dwindle_layout_input;

typedef struct {
    int32_t first_child_index;
    int32_t second_child_index;
    double split_ratio;
    double min_width;
    double min_height;
    uint32_t kind;
    uint32_t orientation;
    uint8_t has_window;
    uint8_t fullscreen;
} omniwm_dwindle_node_input;

typedef struct {
    double x;
    double y;
    double width;
    double height;
    uint8_t has_frame;
} omniwm_dwindle_node_frame;

typedef struct {
    double working_x;
    double working_y;
    double working_width;
    double working_height;
    double view_x;
    double view_y;
    double view_width;
    double view_height;
    double scale;
    double primary_gap;
    double secondary_gap;
    double tab_indicator_width;
    double view_offset;
    double workspace_offset;
    double single_window_aspect_ratio;
    double single_window_aspect_tolerance;
    int32_t active_container_index;
    int32_t hidden_placement_monitor_index;
    uint32_t orientation;
    uint8_t single_window_mode;
} omniwm_niri_layout_input;

typedef struct {
    double span;
    double render_offset_x;
    double render_offset_y;
    uint32_t window_start_index;
    uint32_t window_count;
    uint8_t is_tabbed;
    uint8_t has_manual_single_window_width_override;
} omniwm_niri_container_input;

typedef struct {
    double weight;
    double min_constraint;
    double max_constraint;
    double fixed_value;
    double render_offset_x;
    double render_offset_y;
    uint8_t has_max_constraint;
    uint8_t is_constraint_fixed;
    uint8_t has_fixed_value;
    uint8_t sizing_mode;
} omniwm_niri_window_input;

typedef struct {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    double visible_x;
    double visible_y;
    double visible_width;
    double visible_height;
} omniwm_niri_hidden_placement_monitor;

typedef struct {
    double canonical_x;
    double canonical_y;
    double canonical_width;
    double canonical_height;
    double rendered_x;
    double rendered_y;
    double rendered_width;
    double rendered_height;
} omniwm_niri_container_output;

typedef struct {
    double canonical_x;
    double canonical_y;
    double canonical_width;
    double canonical_height;
    double rendered_x;
    double rendered_y;
    double rendered_width;
    double rendered_height;
    double resolved_span;
    uint8_t hidden_edge;
} omniwm_niri_window_output;

int32_t omniwm_axis_solve(
    const omniwm_axis_input *inputs,
    size_t count,
    double available_space,
    double gap_size,
    uint8_t is_tabbed,
    omniwm_axis_output *outputs
);

int32_t omniwm_dwindle_solve(
    const omniwm_dwindle_layout_input *input,
    const omniwm_dwindle_node_input *nodes,
    size_t node_count,
    omniwm_dwindle_node_frame *outputs,
    size_t output_count
);

int32_t omniwm_niri_layout_solve(
    const omniwm_niri_layout_input *input,
    const omniwm_niri_container_input *containers,
    size_t container_count,
    const omniwm_niri_window_input *windows,
    size_t window_count,
    const omniwm_niri_hidden_placement_monitor *monitors,
    size_t monitor_count,
    omniwm_niri_container_output *container_outputs,
    size_t container_output_count,
    omniwm_niri_window_output *window_outputs,
    size_t window_output_count
);

double omniwm_geometry_container_position(
    const double *spans,
    size_t count,
    double gap,
    size_t index
);

double omniwm_geometry_total_span(
    const double *spans,
    size_t count,
    double gap
);

double omniwm_geometry_centered_offset(
    const double *spans,
    size_t count,
    double gap,
    double viewport_span,
    size_t index
);

double omniwm_geometry_visible_offset(
    const double *spans,
    size_t count,
    double gap,
    double viewport_span,
    int32_t index,
    double current_view_start,
    uint32_t center_mode,
    uint8_t always_center_single_column,
    int32_t from_index,
    double scale
);

typedef struct {
    double screen_x;
    double screen_y;
    double screen_width;
    double screen_height;
    double metrics_scale;
    double available_width;
    double scaled_window_padding;
    double scaled_workspace_label_height;
    double scaled_workspace_section_padding;
    double scaled_window_spacing;
    double thumbnail_width;
    double initial_content_y;
    double content_bottom_padding;
    double total_content_height_override;
    uint8_t has_total_content_height_override;
} omniwm_overview_context;

typedef struct {
    uint32_t generic_window_start_index;
    uint32_t generic_window_count;
    uint32_t niri_column_start_index;
    uint32_t niri_column_count;
} omniwm_overview_workspace_input;

typedef struct {
    uint32_t workspace_index;
    double source_x;
    double source_y;
    double source_width;
    double source_height;
    uint32_t title_sort_rank;
} omniwm_overview_generic_window_input;

typedef struct {
    double preferred_height;
} omniwm_overview_niri_tile_input;

typedef struct {
    uint32_t workspace_index;
    int32_t column_index;
    double width_weight;
    double preferred_width;
    uint32_t tile_start_index;
    uint32_t tile_count;
    uint8_t has_preferred_width;
} omniwm_overview_niri_column_input;

typedef struct {
    uint32_t workspace_index;
    double section_x;
    double section_y;
    double section_width;
    double section_height;
    double label_x;
    double label_y;
    double label_width;
    double label_height;
    double grid_x;
    double grid_y;
    double grid_width;
    double grid_height;
    uint32_t generic_window_output_start_index;
    uint32_t generic_window_output_count;
    uint32_t niri_column_output_start_index;
    uint32_t niri_column_output_count;
    uint32_t niri_tile_output_start_index;
    uint32_t niri_tile_output_count;
    uint32_t drop_zone_output_start_index;
    uint32_t drop_zone_output_count;
} omniwm_overview_section_output;

typedef struct {
    uint32_t input_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
} omniwm_overview_generic_window_output;

typedef struct {
    uint32_t input_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
} omniwm_overview_niri_tile_output;

typedef struct {
    uint32_t input_index;
    int32_t column_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint32_t tile_output_start_index;
    uint32_t tile_output_count;
} omniwm_overview_niri_column_output;

typedef struct {
    uint32_t workspace_index;
    uint32_t insert_index;
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
} omniwm_overview_drop_zone_output;

typedef struct {
    double total_content_height;
    double min_scroll_offset;
    double max_scroll_offset;
    size_t section_count;
    size_t generic_window_output_count;
    size_t niri_column_output_count;
    size_t niri_tile_output_count;
    size_t drop_zone_output_count;
} omniwm_overview_result;

int32_t omniwm_overview_projection_solve(
    const omniwm_overview_context *context,
    const omniwm_overview_workspace_input *workspaces,
    size_t workspace_count,
    const omniwm_overview_generic_window_input *generic_windows,
    size_t generic_window_count,
    const omniwm_overview_niri_column_input *niri_columns,
    size_t niri_column_count,
    const omniwm_overview_niri_tile_input *niri_tiles,
    size_t niri_tile_count,
    omniwm_overview_section_output *section_outputs,
    size_t section_output_capacity,
    omniwm_overview_generic_window_output *generic_window_outputs,
    size_t generic_window_output_capacity,
    omniwm_overview_niri_column_output *niri_column_outputs,
    size_t niri_column_output_capacity,
    omniwm_overview_niri_tile_output *niri_tile_outputs,
    size_t niri_tile_output_capacity,
    omniwm_overview_drop_zone_output *drop_zone_outputs,
    size_t drop_zone_output_capacity,
    omniwm_overview_result *result
);

typedef struct {
    uint32_t display_id;
    double anchor_x;
    double anchor_y;
    double frame_width;
    double frame_height;
} omniwm_restore_snapshot;

typedef struct {
    uint32_t display_id;
    double frame_min_x;
    double frame_max_y;
    double anchor_x;
    double anchor_y;
    double frame_width;
    double frame_height;
} omniwm_restore_monitor;

typedef struct {
    uint32_t snapshot_index;
    uint32_t monitor_index;
} omniwm_restore_assignment;

int32_t omniwm_restore_resolve_assignments(
    const omniwm_restore_snapshot *snapshots,
    size_t snapshot_count,
    const omniwm_restore_monitor *monitors,
    size_t monitor_count,
    const uint8_t *name_penalties,
    size_t name_penalty_count,
    omniwm_restore_assignment *assignments,
    size_t assignment_capacity,
    size_t *assignment_count
);

enum {
    OMNIWM_WINDOW_DECISION_RULE_ACTION_NONE = 0,
    OMNIWM_WINDOW_DECISION_RULE_ACTION_AUTO = 1,
    OMNIWM_WINDOW_DECISION_RULE_ACTION_TILE = 2,
    OMNIWM_WINDOW_DECISION_RULE_ACTION_FLOAT = 3,
};

enum {
    OMNIWM_WINDOW_DECISION_DISPOSITION_MANAGED = 0,
    OMNIWM_WINDOW_DECISION_DISPOSITION_FLOATING = 1,
    OMNIWM_WINDOW_DECISION_DISPOSITION_UNMANAGED = 2,
    OMNIWM_WINDOW_DECISION_DISPOSITION_UNDECIDED = 3,
};

enum {
    OMNIWM_WINDOW_DECISION_SOURCE_USER_RULE = 0,
    OMNIWM_WINDOW_DECISION_SOURCE_BUILT_IN_RULE = 1,
    OMNIWM_WINDOW_DECISION_SOURCE_HEURISTIC = 2,
};

enum {
    OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_NONE = 0,
    OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_DEFAULT_FLOATING_APP = 1,
    OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_BROWSER_PICTURE_IN_PICTURE = 2,
    OMNIWM_WINDOW_DECISION_BUILT_IN_SOURCE_CLEAN_SHOT_RECORDING_OVERLAY = 3,
};

enum {
    OMNIWM_WINDOW_DECISION_LAYOUT_KIND_EXPLICIT = 0,
    OMNIWM_WINDOW_DECISION_LAYOUT_KIND_FALLBACK = 1,
};

enum {
    OMNIWM_WINDOW_DECISION_DEFERRED_REASON_NONE = 0,
    OMNIWM_WINDOW_DECISION_DEFERRED_REASON_ATTRIBUTE_FETCH_FAILED = 1,
    OMNIWM_WINDOW_DECISION_DEFERRED_REASON_REQUIRED_TITLE_MISSING = 2,
};

enum {
    OMNIWM_WINDOW_DECISION_SPECIAL_CASE_NONE = 0,
    OMNIWM_WINDOW_DECISION_SPECIAL_CASE_CLEAN_SHOT_RECORDING_OVERLAY = 1,
};

enum {
    OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_UNKNOWN = 0,
    OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_REGULAR = 1,
    OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_ACCESSORY = 2,
    OMNIWM_WINDOW_DECISION_ACTIVATION_POLICY_PROHIBITED = 3,
};

enum {
    OMNIWM_WINDOW_DECISION_SUBROLE_KIND_UNKNOWN = 0,
    OMNIWM_WINDOW_DECISION_SUBROLE_KIND_STANDARD = 1,
    OMNIWM_WINDOW_DECISION_SUBROLE_KIND_NONSTANDARD = 2,
};

enum {
    OMNIWM_WINDOW_DECISION_FULLSCREEN_BUTTON_STATE_UNKNOWN = 0,
    OMNIWM_WINDOW_DECISION_FULLSCREEN_BUTTON_STATE_ENABLED = 1,
    OMNIWM_WINDOW_DECISION_FULLSCREEN_BUTTON_STATE_DISABLED = 2,
};

enum {
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_ATTRIBUTE_FETCH_FAILED = 1u << 0,
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_BROWSER_PICTURE_IN_PICTURE = 1u << 1,
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_ACCESSORY_WITHOUT_CLOSE = 1u << 2,
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_TRUSTED_FLOATING_SUBROLE = 1u << 3,
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_NO_BUTTONS_ON_NONSTANDARD_SUBROLE = 1u << 4,
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_NONSTANDARD_SUBROLE = 1u << 5,
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_MISSING_FULLSCREEN_BUTTON = 1u << 6,
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_DISABLED_FULLSCREEN_BUTTON = 1u << 7,
    OMNIWM_WINDOW_DECISION_HEURISTIC_REASON_FIXED_SIZE_WINDOW = 1u << 8,
};

typedef struct {
    uint32_t action;
    uint8_t has_match;
} omniwm_window_decision_rule_summary;

typedef struct {
    uint32_t action;
    uint32_t source_kind;
    uint8_t has_match;
} omniwm_window_decision_built_in_rule_summary;

typedef struct {
    omniwm_window_decision_rule_summary matched_user_rule;
    omniwm_window_decision_built_in_rule_summary matched_built_in_rule;
    uint32_t special_case_kind;
    uint32_t activation_policy;
    uint32_t subrole_kind;
    uint32_t fullscreen_button_state;
    uint8_t title_required;
    uint8_t title_present;
    uint8_t attribute_fetch_succeeded;
    uint8_t app_fullscreen;
    uint8_t has_close_button;
    uint8_t has_fullscreen_button;
    uint8_t has_zoom_button;
    uint8_t has_minimize_button;
} omniwm_window_decision_input;

typedef struct {
    uint32_t disposition;
    uint32_t source_kind;
    uint32_t built_in_source_kind;
    uint32_t layout_kind;
    uint32_t deferred_reason;
    uint32_t heuristic_reason_bits;
} omniwm_window_decision_output;

int32_t omniwm_window_decision_solve(
    const omniwm_window_decision_input *input,
    omniwm_window_decision_output *output
);

enum {
    OMNIWM_RECONCILE_EVENT_WINDOW_ADMITTED = 0,
    OMNIWM_RECONCILE_EVENT_WINDOW_REKEYED = 1,
    OMNIWM_RECONCILE_EVENT_WINDOW_REMOVED = 2,
    OMNIWM_RECONCILE_EVENT_WORKSPACE_ASSIGNED = 3,
    OMNIWM_RECONCILE_EVENT_WINDOW_MODE_CHANGED = 4,
    OMNIWM_RECONCILE_EVENT_FLOATING_GEOMETRY_UPDATED = 5,
    OMNIWM_RECONCILE_EVENT_HIDDEN_STATE_CHANGED = 6,
    OMNIWM_RECONCILE_EVENT_NATIVE_FULLSCREEN_TRANSITION = 7,
    OMNIWM_RECONCILE_EVENT_MANAGED_REPLACEMENT_METADATA_CHANGED = 8,
    OMNIWM_RECONCILE_EVENT_TOPOLOGY_CHANGED = 9,
    OMNIWM_RECONCILE_EVENT_ACTIVE_SPACE_CHANGED = 10,
    OMNIWM_RECONCILE_EVENT_FOCUS_LEASE_CHANGED = 11,
    OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_REQUESTED = 12,
    OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_CONFIRMED = 13,
    OMNIWM_RECONCILE_EVENT_MANAGED_FOCUS_CANCELLED = 14,
    OMNIWM_RECONCILE_EVENT_NON_MANAGED_FOCUS_CHANGED = 15,
    OMNIWM_RECONCILE_EVENT_SYSTEM_SLEEP = 16,
    OMNIWM_RECONCILE_EVENT_SYSTEM_WAKE = 17,
};

enum {
    OMNIWM_RECONCILE_WINDOW_MODE_TILING = 0,
    OMNIWM_RECONCILE_WINDOW_MODE_FLOATING = 1,
};

enum {
    OMNIWM_RECONCILE_LIFECYCLE_DISCOVERED = 0,
    OMNIWM_RECONCILE_LIFECYCLE_ADMITTED = 1,
    OMNIWM_RECONCILE_LIFECYCLE_TILED = 2,
    OMNIWM_RECONCILE_LIFECYCLE_FLOATING = 3,
    OMNIWM_RECONCILE_LIFECYCLE_HIDDEN = 4,
    OMNIWM_RECONCILE_LIFECYCLE_OFFSCREEN = 5,
    OMNIWM_RECONCILE_LIFECYCLE_RESTORING = 6,
    OMNIWM_RECONCILE_LIFECYCLE_REPLACING = 7,
    OMNIWM_RECONCILE_LIFECYCLE_NATIVE_FULLSCREEN = 8,
    OMNIWM_RECONCILE_LIFECYCLE_DESTROYED = 9,
};

enum {
    OMNIWM_RECONCILE_REPLACEMENT_REASON_MANAGED_REPLACEMENT = 0,
    OMNIWM_RECONCILE_REPLACEMENT_REASON_NATIVE_FULLSCREEN = 1,
    OMNIWM_RECONCILE_REPLACEMENT_REASON_MANUAL_REKEY = 2,
};

enum {
    OMNIWM_RECONCILE_HIDDEN_STATE_VISIBLE = 0,
    OMNIWM_RECONCILE_HIDDEN_STATE_HIDDEN = 1,
    OMNIWM_RECONCILE_HIDDEN_STATE_OFFSCREEN_LEFT = 2,
    OMNIWM_RECONCILE_HIDDEN_STATE_OFFSCREEN_RIGHT = 3,
};

enum {
    OMNIWM_RECONCILE_NOTE_NONE = 0,
    OMNIWM_RECONCILE_NOTE_MANAGED_REPLACEMENT_METADATA_CHANGED = 1,
    OMNIWM_RECONCILE_NOTE_TOPOLOGY_CHANGED = 2,
    OMNIWM_RECONCILE_NOTE_ACTIVE_SPACE_CHANGED = 3,
    OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_SET = 4,
    OMNIWM_RECONCILE_NOTE_FOCUS_LEASE_CLEARED = 5,
    OMNIWM_RECONCILE_NOTE_SYSTEM_SLEEP = 6,
    OMNIWM_RECONCILE_NOTE_SYSTEM_WAKE = 7,
};

enum {
    OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_KEEP_EXISTING = 0,
    OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_CLEAR = 1,
    OMNIWM_RECONCILE_FOCUS_LEASE_ACTION_SET_FROM_EVENT = 2,
};

typedef struct {
    uint64_t high;
    uint64_t low;
} omniwm_uuid;

typedef struct {
    int32_t pid;
    int64_t window_id;
} omniwm_window_token;

typedef struct {
    double x;
    double y;
} omniwm_point;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} omniwm_rect;

typedef struct {
    omniwm_rect frame;
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint8_t has_frame;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
    uint8_t is_visible;
    uint8_t is_focused;
    uint8_t has_ax_reference;
    uint8_t is_native_fullscreen;
} omniwm_reconcile_observed_state;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint32_t disposition;
    omniwm_rect floating_frame;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
    uint8_t has_disposition;
    uint8_t has_floating_frame;
    uint8_t rescue_eligible;
} omniwm_reconcile_desired_state;

typedef struct {
    omniwm_rect last_frame;
    omniwm_point normalized_origin;
    uint32_t reference_monitor_id;
    uint8_t has_normalized_origin;
    uint8_t has_reference_monitor_id;
    uint8_t restore_to_floating;
} omniwm_reconcile_floating_state;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t mode;
    omniwm_reconcile_observed_state observed_state;
    omniwm_reconcile_desired_state desired_state;
    omniwm_reconcile_floating_state floating_state;
    uint8_t has_floating_state;
} omniwm_reconcile_entry;

typedef struct {
    uint32_t display_id;
    omniwm_rect visible_frame;
} omniwm_reconcile_monitor;

typedef struct {
    omniwm_window_token token;
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint8_t has_token;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
} omniwm_reconcile_pending_focus;

typedef struct {
    omniwm_window_token focused_token;
    omniwm_reconcile_pending_focus pending_managed_focus;
    uint8_t has_focused_token;
    uint8_t is_non_managed_focus_active;
    uint8_t is_app_fullscreen_active;
} omniwm_reconcile_focus_session;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint32_t target_mode;
    omniwm_rect floating_frame;
    uint8_t has_monitor_id;
    uint8_t has_floating_frame;
} omniwm_reconcile_persisted_hydration;

typedef struct {
    uint32_t kind;
    omniwm_window_token token;
    omniwm_window_token secondary_token;
    omniwm_uuid workspace_id;
    omniwm_uuid secondary_workspace_id;
    uint32_t monitor_id;
    uint32_t mode;
    omniwm_rect frame;
    uint32_t hidden_state;
    uint32_t replacement_reason;
    uint8_t has_secondary_token;
    uint8_t has_workspace_id;
    uint8_t has_secondary_workspace_id;
    uint8_t has_monitor_id;
    uint8_t has_mode;
    uint8_t has_frame;
    uint8_t restore_to_floating;
    uint8_t is_active;
    uint8_t app_fullscreen;
    uint8_t preserve_focused_token;
    uint8_t has_focus_lease;
} omniwm_reconcile_event;

typedef struct {
    omniwm_uuid workspace_id;
    int32_t preferred_monitor_index;
    omniwm_rect floating_frame;
    omniwm_point normalized_floating_origin;
    uint8_t has_floating_frame;
    uint8_t has_normalized_floating_origin;
    uint8_t restore_to_floating;
    uint8_t rescue_eligible;
} omniwm_reconcile_restore_intent_output;

typedef struct {
    omniwm_window_token previous_token;
    omniwm_window_token next_token;
    uint32_t reason;
} omniwm_reconcile_replacement_correlation;

typedef struct {
    omniwm_window_token focused_token;
    omniwm_reconcile_pending_focus pending_managed_focus;
    uint32_t focus_lease_action;
    uint8_t has_focused_token;
    uint8_t is_non_managed_focus_active;
    uint8_t is_app_fullscreen_active;
} omniwm_reconcile_focus_session_output;

typedef struct {
    uint32_t lifecycle_phase;
    omniwm_reconcile_observed_state observed_state;
    omniwm_reconcile_desired_state desired_state;
    omniwm_reconcile_restore_intent_output restore_intent;
    omniwm_reconcile_replacement_correlation replacement_correlation;
    omniwm_reconcile_focus_session_output focus_session;
    uint8_t has_lifecycle_phase;
    uint8_t has_observed_state;
    uint8_t has_desired_state;
    uint8_t has_restore_intent;
    uint8_t has_replacement_correlation;
    uint8_t has_focus_session;
    uint32_t note_code;
} omniwm_reconcile_plan_output;

int32_t omniwm_reconcile_plan(
    const omniwm_reconcile_event *event,
    const omniwm_reconcile_entry *existing_entry,
    const omniwm_reconcile_focus_session *focus_session,
    const omniwm_reconcile_monitor *monitors,
    size_t monitor_count,
    const omniwm_reconcile_persisted_hydration *persisted_hydration,
    omniwm_reconcile_plan_output *output
);

int32_t omniwm_reconcile_restore_intent(
    const omniwm_reconcile_entry *entry,
    const omniwm_reconcile_monitor *monitors,
    size_t monitor_count,
    omniwm_reconcile_restore_intent_output *output
);

enum {
    OMNIWM_ORCHESTRATION_LAYOUT_KIND_DEFAULT = 0,
    OMNIWM_ORCHESTRATION_LAYOUT_KIND_NIRI = 1,
    OMNIWM_ORCHESTRATION_LAYOUT_KIND_DWINDLE = 2,
};

enum {
    OMNIWM_ORCHESTRATION_REFRESH_KIND_RELAYOUT = 0,
    OMNIWM_ORCHESTRATION_REFRESH_KIND_IMMEDIATE_RELAYOUT = 1,
    OMNIWM_ORCHESTRATION_REFRESH_KIND_VISIBILITY_REFRESH = 2,
    OMNIWM_ORCHESTRATION_REFRESH_KIND_WINDOW_REMOVAL = 3,
    OMNIWM_ORCHESTRATION_REFRESH_KIND_FULL_RESCAN = 4,
};

enum {
    OMNIWM_ORCHESTRATION_REFRESH_REASON_STARTUP = 0,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_LAUNCHED = 1,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_UNLOCK = 2,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_ACTIVE_SPACE_CHANGED = 3,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_CONFIGURATION_CHANGED = 4,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_RULES_CHANGED = 5,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_CONFIG_CHANGED = 6,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_CONFIG_CHANGED = 7,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_MONITOR_SETTINGS_CHANGED = 8,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_GAPS_CHANGED = 9,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_TRANSITION = 10,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_ACTIVATION_TRANSITION = 11,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_WORKSPACE_LAYOUT_TOGGLED = 12,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_TERMINATED = 13,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_RULE_REEVALUATION = 14,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_LAYOUT_COMMAND = 15,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_INTERACTIVE_GESTURE = 16,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CREATED = 17,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_AX_WINDOW_CHANGED = 18,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_WINDOW_DESTROYED = 19,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_HIDDEN = 20,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_APP_UNHIDDEN = 21,
    OMNIWM_ORCHESTRATION_REFRESH_REASON_OVERVIEW_MUTATION = 22,
};

enum {
    OMNIWM_ORCHESTRATION_EVENT_REFRESH_REQUESTED = 0,
    OMNIWM_ORCHESTRATION_EVENT_REFRESH_COMPLETED = 1,
    OMNIWM_ORCHESTRATION_EVENT_FOCUS_REQUESTED = 2,
    OMNIWM_ORCHESTRATION_EVENT_ACTIVATION_OBSERVED = 3,
};

enum {
    OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_FOCUSED_WINDOW_CHANGED = 0,
    OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_WORKSPACE_DID_ACTIVATE_APPLICATION = 1,
    OMNIWM_ORCHESTRATION_ACTIVATION_SOURCE_CGS_FRONT_APP_CHANGED = 2,
};

enum {
    OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_EXTERNAL = 0,
    OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_PROBE = 1,
    OMNIWM_ORCHESTRATION_ACTIVATION_ORIGIN_RETRY = 2,
};

enum {
    OMNIWM_ORCHESTRATION_RETRY_REASON_MISSING_FOCUSED_WINDOW = 0,
    OMNIWM_ORCHESTRATION_RETRY_REASON_PENDING_FOCUS_MISMATCH = 1,
    OMNIWM_ORCHESTRATION_RETRY_REASON_PENDING_FOCUS_UNMANAGED_TOKEN = 2,
    OMNIWM_ORCHESTRATION_RETRY_REASON_RETRY_EXHAUSTED = 3,
};

enum {
    OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_MISSING_FOCUSED_WINDOW = 0,
    OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_MANAGED = 1,
    OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_UNMANAGED = 2,
    OMNIWM_ORCHESTRATION_ACTIVATION_MATCH_OWNED_APPLICATION = 3,
};

enum {
    OMNIWM_ORCHESTRATION_DECISION_REFRESH_DROPPED = 0,
    OMNIWM_ORCHESTRATION_DECISION_REFRESH_QUEUED = 1,
    OMNIWM_ORCHESTRATION_DECISION_REFRESH_MERGED = 2,
    OMNIWM_ORCHESTRATION_DECISION_REFRESH_SUPERSEDED = 3,
    OMNIWM_ORCHESTRATION_DECISION_REFRESH_COMPLETED = 4,
    OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_ACCEPTED = 5,
    OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_SUPERSEDED = 6,
    OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_CONTINUED = 7,
    OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_CANCELLED = 8,
    OMNIWM_ORCHESTRATION_DECISION_FOCUS_REQUEST_IGNORED = 9,
    OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_CONFIRMED = 10,
    OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_DEFERRED = 11,
    OMNIWM_ORCHESTRATION_DECISION_MANAGED_ACTIVATION_FALLBACK = 12,
};

enum {
    OMNIWM_ORCHESTRATION_ACTION_CANCEL_ACTIVE_REFRESH = 0,
    OMNIWM_ORCHESTRATION_ACTION_START_REFRESH = 1,
    OMNIWM_ORCHESTRATION_ACTION_RUN_POST_LAYOUT_ATTACHMENTS = 2,
    OMNIWM_ORCHESTRATION_ACTION_DISCARD_POST_LAYOUT_ATTACHMENTS = 3,
    OMNIWM_ORCHESTRATION_ACTION_PERFORM_VISIBILITY_SIDE_EFFECTS = 4,
    OMNIWM_ORCHESTRATION_ACTION_REQUEST_WORKSPACE_BAR_REFRESH = 5,
    OMNIWM_ORCHESTRATION_ACTION_BEGIN_MANAGED_FOCUS_REQUEST = 6,
    OMNIWM_ORCHESTRATION_ACTION_FRONT_MANAGED_WINDOW = 7,
    OMNIWM_ORCHESTRATION_ACTION_CLEAR_MANAGED_FOCUS_STATE = 8,
    OMNIWM_ORCHESTRATION_ACTION_CONTINUE_MANAGED_FOCUS_REQUEST = 9,
    OMNIWM_ORCHESTRATION_ACTION_CONFIRM_MANAGED_ACTIVATION = 10,
    OMNIWM_ORCHESTRATION_ACTION_BEGIN_NATIVE_FULLSCREEN_RESTORE_ACTIVATION = 11,
    OMNIWM_ORCHESTRATION_ACTION_ENTER_NON_MANAGED_FALLBACK = 12,
    OMNIWM_ORCHESTRATION_ACTION_CANCEL_ACTIVATION_RETRY = 13,
    OMNIWM_ORCHESTRATION_ACTION_ENTER_OWNED_APPLICATION_FALLBACK = 14,
};

typedef struct {
    omniwm_window_token token;
    omniwm_rect frame;
} omniwm_orchestration_old_frame_record;

typedef struct {
    omniwm_uuid workspace_id;
    omniwm_uuid removed_node_id;
    uint32_t layout_kind;
    uint8_t has_removed_node_id;
    uint8_t should_recover_focus;
    uint8_t reserved0;
    uint8_t reserved1;
    size_t old_frame_offset;
    size_t old_frame_count;
} omniwm_orchestration_window_removal_payload;

typedef struct {
    uint32_t kind;
    uint32_t reason;
    size_t affected_workspace_offset;
    size_t affected_workspace_count;
} omniwm_orchestration_follow_up_refresh;

typedef struct {
    uint64_t cycle_id;
    uint32_t kind;
    uint32_t reason;
    size_t affected_workspace_offset;
    size_t affected_workspace_count;
    size_t post_layout_attachment_offset;
    size_t post_layout_attachment_count;
    size_t window_removal_payload_offset;
    size_t window_removal_payload_count;
    omniwm_orchestration_follow_up_refresh follow_up_refresh;
    uint32_t visibility_reason;
    uint8_t has_follow_up_refresh;
    uint8_t needs_visibility_reconciliation;
    uint8_t has_visibility_reason;
    uint8_t reserved0;
} omniwm_orchestration_refresh;

typedef struct {
    uint64_t request_id;
    omniwm_window_token token;
    omniwm_uuid workspace_id;
    uint32_t retry_count;
    uint32_t last_activation_source;
    uint8_t has_last_activation_source;
    uint8_t reserved0;
    uint8_t reserved1;
    uint8_t reserved2;
} omniwm_orchestration_managed_request;

typedef struct {
    omniwm_orchestration_refresh active_refresh;
    omniwm_orchestration_refresh pending_refresh;
    uint8_t has_active_refresh;
    uint8_t has_pending_refresh;
    uint8_t reserved0;
    uint8_t reserved1;
} omniwm_orchestration_refresh_snapshot;

typedef struct {
    uint64_t next_managed_request_id;
    omniwm_orchestration_managed_request active_managed_request;
    omniwm_window_token pending_focused_token;
    omniwm_uuid pending_focused_workspace_id;
    uint8_t has_active_managed_request;
    uint8_t has_pending_focused_token;
    uint8_t has_pending_focused_workspace_id;
    uint8_t is_non_managed_focus_active;
    uint8_t is_app_fullscreen_active;
    uint8_t reserved0;
    uint8_t reserved1;
    uint8_t reserved2;
} omniwm_orchestration_focus_snapshot;

typedef struct {
    omniwm_orchestration_refresh_snapshot refresh;
    omniwm_orchestration_focus_snapshot focus;
} omniwm_orchestration_snapshot;

typedef struct {
    omniwm_orchestration_refresh refresh;
    uint8_t should_drop_while_busy;
    uint8_t is_incremental_refresh_in_progress;
    uint8_t is_immediate_layout_in_progress;
    uint8_t has_active_animation_refreshes;
} omniwm_orchestration_refresh_request_event;

typedef struct {
    omniwm_orchestration_refresh refresh;
    uint8_t did_complete;
    uint8_t did_execute_plan;
    uint8_t reserved0;
    uint8_t reserved1;
} omniwm_orchestration_refresh_completion_event;

typedef struct {
    omniwm_window_token token;
    omniwm_uuid workspace_id;
} omniwm_orchestration_focus_request_event;

typedef struct {
    uint32_t source;
    uint32_t origin;
    uint32_t match_kind;
    int32_t pid;
    omniwm_window_token token;
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint8_t has_token;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
    uint8_t is_workspace_active;
    uint8_t app_fullscreen;
    uint8_t fallback_fullscreen;
    uint8_t requires_native_fullscreen_restore_relayout;
    uint8_t reserved0;
    uint8_t reserved1;
} omniwm_orchestration_activation_observation;

typedef struct {
    uint32_t kind;
    omniwm_orchestration_refresh_request_event refresh_request;
    omniwm_orchestration_refresh_completion_event refresh_completion;
    omniwm_orchestration_focus_request_event focus_request;
    omniwm_orchestration_activation_observation activation_observation;
} omniwm_orchestration_event;

typedef struct {
    uint32_t kind;
    uint32_t refresh_kind;
    uint32_t refresh_reason;
    uint32_t retry_reason;
    uint64_t cycle_id;
    uint64_t secondary_cycle_id;
    uint64_t request_id;
    uint64_t secondary_request_id;
    int32_t pid;
    omniwm_window_token token;
    uint8_t has_token;
    uint8_t did_complete;
    uint8_t reserved0;
    uint8_t reserved1;
} omniwm_orchestration_decision;

typedef struct {
    uint32_t kind;
    uint32_t retry_reason;
    uint32_t activation_source;
    uint32_t activation_origin;
    uint64_t cycle_id;
    uint64_t request_id;
    int32_t pid;
    omniwm_window_token token;
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    size_t attachment_offset;
    size_t attachment_count;
    uint8_t has_token;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
    uint8_t is_workspace_active;
    uint8_t app_fullscreen;
    uint8_t reserved0;
    uint8_t reserved1;
    uint8_t reserved2;
} omniwm_orchestration_action;

typedef struct {
    omniwm_orchestration_snapshot snapshot;
    omniwm_orchestration_event event;
    /* Input side buffers are immutable and caller-owned. Offset/count pairs in
       snapshot and event records address these arrays. A null pointer is valid
       only when the matching count is zero. */
    const omniwm_uuid *workspace_ids;
    size_t workspace_id_count;
    const uint64_t *attachment_ids;
    size_t attachment_id_count;
    const omniwm_orchestration_window_removal_payload *window_removal_payloads;
    size_t window_removal_payload_count;
    const omniwm_orchestration_old_frame_record *old_frame_records;
    size_t old_frame_record_count;
} omniwm_orchestration_step_input;

typedef struct {
    omniwm_orchestration_snapshot snapshot;
    omniwm_orchestration_decision decision;
    /* Output side buffers are caller-owned. The kernel writes up to each
       capacity, sets the matching count fields, and returns
       OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL without allocating when any output
       buffer is insufficient. A null pointer is valid only for zero capacity. */
    omniwm_orchestration_action *actions;
    size_t action_capacity;
    size_t action_count;
    omniwm_uuid *snapshot_workspace_ids;
    size_t snapshot_workspace_id_capacity;
    size_t snapshot_workspace_id_count;
    uint64_t *snapshot_attachment_ids;
    size_t snapshot_attachment_id_capacity;
    size_t snapshot_attachment_id_count;
    omniwm_orchestration_window_removal_payload *snapshot_window_removal_payloads;
    size_t snapshot_window_removal_payload_capacity;
    size_t snapshot_window_removal_payload_count;
    omniwm_orchestration_old_frame_record *snapshot_old_frame_records;
    size_t snapshot_old_frame_record_capacity;
    size_t snapshot_old_frame_record_count;
    uint64_t *action_attachment_ids;
    size_t action_attachment_id_capacity;
    size_t action_attachment_id_count;
} omniwm_orchestration_step_output;

typedef struct {
    size_t step_input_size;
    size_t step_input_alignment;
    size_t step_input_snapshot_offset;
    size_t step_input_event_offset;
    size_t step_input_workspace_ids_offset;
    size_t step_input_window_removal_payloads_offset;
    size_t step_output_size;
    size_t step_output_alignment;
    size_t step_output_snapshot_offset;
    size_t step_output_decision_offset;
    size_t step_output_actions_offset;
    size_t step_output_action_count_offset;
    size_t snapshot_size;
    size_t snapshot_alignment;
    size_t event_size;
    size_t event_alignment;
    size_t refresh_size;
    size_t refresh_alignment;
    size_t managed_request_size;
    size_t managed_request_alignment;
    size_t action_size;
    size_t action_alignment;
} omniwm_orchestration_abi_layout_info;

/* Runs one deterministic orchestration reducer/planner step. Swift owns object
   lifetimes, platform effects, and all buffers; Zig only reads the flattened
   input and writes the next snapshot, decision tag, and ordered actions. */
int32_t omniwm_orchestration_step(
    const omniwm_orchestration_step_input *input,
    omniwm_orchestration_step_output *output
);

int32_t omniwm_orchestration_get_abi_layout(
    omniwm_orchestration_abi_layout_info *out_layout
);

#ifdef __cplusplus
}
#endif

#endif
