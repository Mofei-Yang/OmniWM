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

enum {
    OMNIWM_NIRI_TOPOLOGY_OP_ADD_WINDOW = 0,
    OMNIWM_NIRI_TOPOLOGY_OP_REMOVE_WINDOW = 1,
    OMNIWM_NIRI_TOPOLOGY_OP_SYNC_WINDOWS = 2,
    OMNIWM_NIRI_TOPOLOGY_OP_FOCUS = 3,
    OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_COLUMN = 4,
    OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_WINDOW_IN_COLUMN = 5,
    OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_COMBINED = 6,
    OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE = 7,
    OMNIWM_NIRI_TOPOLOGY_OP_MOVE_COLUMN = 8,
    OMNIWM_NIRI_TOPOLOGY_OP_MOVE_WINDOW = 9,
    OMNIWM_NIRI_TOPOLOGY_OP_COLUMN_REMOVAL = 10,
    OMNIWM_NIRI_TOPOLOGY_OP_INSERT_WINDOW_IN_NEW_COLUMN = 11,
    OMNIWM_NIRI_TOPOLOGY_OP_SWAP_WINDOWS = 12,
    OMNIWM_NIRI_TOPOLOGY_OP_INSERT_WINDOW_BY_MOVE = 13,
};

enum {
    OMNIWM_NIRI_TOPOLOGY_DIRECTION_LEFT = 0,
    OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT = 1,
    OMNIWM_NIRI_TOPOLOGY_DIRECTION_UP = 2,
    OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN = 3,
};

enum {
    OMNIWM_NIRI_TOPOLOGY_INSERT_BEFORE = 0,
    OMNIWM_NIRI_TOPOLOGY_INSERT_AFTER = 1,
};

enum {
    OMNIWM_NIRI_TOPOLOGY_VIEWPORT_NONE = 0,
    OMNIWM_NIRI_TOPOLOGY_VIEWPORT_DELTA_ONLY = 1,
    OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC = 2,
    OMNIWM_NIRI_TOPOLOGY_VIEWPORT_ANIMATE = 3,
};

enum {
    OMNIWM_NIRI_TOPOLOGY_EFFECT_NONE = 0,
    OMNIWM_NIRI_TOPOLOGY_EFFECT_REMOVE_COLUMN = 1,
    OMNIWM_NIRI_TOPOLOGY_EFFECT_ADD_COLUMN = 2,
    OMNIWM_NIRI_TOPOLOGY_EFFECT_MOVE_COLUMN = 3,
    OMNIWM_NIRI_TOPOLOGY_EFFECT_EXPEL_WINDOW = 4,
    OMNIWM_NIRI_TOPOLOGY_EFFECT_CONSUME_WINDOW = 5,
    OMNIWM_NIRI_TOPOLOGY_EFFECT_REORDER_WINDOW = 6,
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

typedef struct {
    uint64_t id;
    double span;
    uint32_t window_start_index;
    uint32_t window_count;
    int32_t active_window_index;
    uint8_t is_tabbed;
} omniwm_niri_topology_column_input;

typedef struct {
    uint64_t id;
    uint8_t sizing_mode;
} omniwm_niri_topology_window_input;

typedef struct {
    double view_pos;
    int32_t column_index;
} omniwm_geometry_snap_target_result;

typedef struct {
    uint32_t operation;
    uint32_t direction;
    uint32_t orientation;
    uint32_t center_mode;
    uint64_t subject_window_id;
    uint64_t target_window_id;
    uint64_t selected_window_id;
    uint64_t focused_window_id;
    int32_t active_column_index;
    int32_t insert_index;
    int32_t target_index;
    int32_t from_column_index;
    uint32_t max_windows_per_column;
    double gap;
    double viewport_span;
    double current_view_offset;
    double stationary_view_offset;
    double scale;
    double default_new_column_span;
    double previous_active_position;
    double activate_prev_column_on_removal;
    uint8_t infinite_loop;
    uint8_t always_center_single_column;
    uint8_t animate;
    uint8_t has_previous_active_position;
    uint8_t has_activate_prev_column_on_removal;
    uint8_t reset_for_single_window;
    uint8_t is_active_workspace;
    uint8_t has_completed_initial_refresh;
    uint8_t viewport_is_gesture_or_animation;
} omniwm_niri_topology_input;

typedef struct {
    uint64_t id;
    uint32_t window_start_index;
    uint32_t window_count;
    int32_t active_window_index;
    uint8_t is_tabbed;
} omniwm_niri_topology_column_output;

typedef struct {
    uint64_t id;
} omniwm_niri_topology_window_output;

typedef struct {
    size_t column_count;
    size_t window_count;
    uint64_t selected_window_id;
    uint64_t remembered_focus_window_id;
    uint64_t new_window_id;
    uint64_t fallback_window_id;
    int32_t active_column_index;
    int32_t source_column_index;
    int32_t target_column_index;
    int32_t source_window_index;
    int32_t target_window_index;
    uint32_t viewport_action;
    uint32_t effect_kind;
    double viewport_offset_delta;
    double viewport_target_offset;
    double restore_previous_view_offset;
    double activate_prev_column_on_removal;
    uint8_t has_restore_previous_view_offset;
    uint8_t has_activate_prev_column_on_removal;
    uint8_t should_clear_activate_prev_column_on_removal;
    uint8_t source_column_became_empty;
    uint8_t inserted_before_active;
    uint8_t did_apply;
} omniwm_niri_topology_result;

int32_t omniwm_axis_solve(
    const omniwm_axis_input *inputs,
    size_t count,
    double available_space,
    double gap_size,
    uint8_t is_tabbed,
    omniwm_axis_output *outputs
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

int32_t omniwm_niri_topology_plan(
    const omniwm_niri_topology_input *input,
    const omniwm_niri_topology_column_input *columns,
    size_t column_count,
    const omniwm_niri_topology_window_input *windows,
    size_t window_count,
    const uint64_t *desired_window_ids,
    size_t desired_window_count,
    const uint64_t *removed_window_ids,
    size_t removed_window_count,
    omniwm_niri_topology_column_output *column_outputs,
    size_t column_output_capacity,
    omniwm_niri_topology_window_output *window_outputs,
    size_t window_output_capacity,
    omniwm_niri_topology_result *result
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
    const uint8_t *modes,
    size_t count,
    double gap,
    double viewport_span,
    size_t index
);

double omniwm_geometry_visible_offset(
    const double *spans,
    const uint8_t *modes,
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

omniwm_geometry_snap_target_result omniwm_geometry_snap_target(
    const double *spans,
    const uint8_t *modes,
    size_t count,
    double gap,
    double viewport_span,
    double projected_view_pos,
    double current_view_pos,
    uint32_t center_mode,
    uint8_t always_center_single_column
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
    OMNIWM_RESTORE_EVENT_KIND_OTHER = 0,
    OMNIWM_RESTORE_EVENT_KIND_TOPOLOGY_CHANGED = 1,
    OMNIWM_RESTORE_EVENT_KIND_ACTIVE_SPACE_CHANGED = 2,
    OMNIWM_RESTORE_EVENT_KIND_SYSTEM_WAKE = 3,
    OMNIWM_RESTORE_EVENT_KIND_SYSTEM_SLEEP = 4,
};

enum {
    OMNIWM_RESTORE_NOTE_NONE = 0,
    OMNIWM_RESTORE_NOTE_TOPOLOGY = 1,
    OMNIWM_RESTORE_NOTE_ACTIVE_SPACE = 2,
    OMNIWM_RESTORE_NOTE_SYSTEM_WAKE = 3,
    OMNIWM_RESTORE_NOTE_SYSTEM_SLEEP = 4,
};

enum {
    OMNIWM_RESTORE_CACHE_SOURCE_EXISTING = 0,
    OMNIWM_RESTORE_CACHE_SOURCE_REMOVED_MONITOR = 1,
};

enum {
    OMNIWM_RESTORE_HYDRATION_OUTCOME_NONE = 0,
    OMNIWM_RESTORE_HYDRATION_OUTCOME_MATCHED = 1,
    OMNIWM_RESTORE_HYDRATION_OUTCOME_AMBIGUOUS = 2,
    OMNIWM_RESTORE_HYDRATION_OUTCOME_WORKSPACE_UNRESOLVED = 3,
};

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
    uint64_t high;
    uint64_t low;
} omniwm_uuid;

typedef struct {
    int32_t pid;
    int64_t window_id;
} omniwm_window_token;

typedef struct {
    size_t offset;
    size_t length;
} omniwm_restore_string_ref;

typedef struct {
    uint32_t display_id;
    double anchor_x;
    double anchor_y;
    double frame_width;
    double frame_height;
    omniwm_restore_string_ref name;
    uint8_t has_name;
} omniwm_restore_monitor_key;

typedef struct {
    double frame_min_x;
    double frame_max_y;
    omniwm_rect visible_frame;
    omniwm_restore_monitor_key key;
} omniwm_restore_monitor_context;

typedef struct {
    uint32_t event_kind;
    const uint32_t *sorted_monitor_ids;
    size_t sorted_monitor_count;
    uint32_t interaction_monitor_id;
    uint32_t previous_interaction_monitor_id;
    uint8_t has_interaction_monitor_id;
    uint8_t has_previous_interaction_monitor_id;
} omniwm_restore_event_input;

typedef struct {
    uint32_t interaction_monitor_id;
    uint32_t previous_interaction_monitor_id;
    uint32_t note_code;
    uint8_t refresh_restore_intents;
    uint8_t has_interaction_monitor_id;
    uint8_t has_previous_interaction_monitor_id;
} omniwm_restore_event_output;

typedef struct {
    omniwm_uuid workspace_id;
    omniwm_restore_monitor_key monitor_key;
} omniwm_restore_visible_workspace_snapshot;

typedef struct {
    omniwm_uuid workspace_id;
    omniwm_restore_monitor_key monitor_key;
} omniwm_restore_disconnected_cache_entry;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t home_monitor_id;
    uint32_t effective_monitor_id;
    uint8_t workspace_exists;
    uint8_t has_home_monitor_id;
    uint8_t has_effective_monitor_id;
} omniwm_restore_workspace_monitor_fact;

typedef struct {
    const omniwm_restore_monitor_context *previous_monitors;
    size_t previous_monitor_count;
    const omniwm_restore_monitor_context *new_monitors;
    size_t new_monitor_count;
    const omniwm_restore_visible_workspace_snapshot *visible_workspaces;
    size_t visible_workspace_count;
    const uint8_t *visible_workspace_name_penalties;
    size_t visible_workspace_name_penalty_count;
    const omniwm_restore_disconnected_cache_entry *disconnected_cache_entries;
    size_t disconnected_cache_entry_count;
    const omniwm_restore_workspace_monitor_fact *workspace_facts;
    size_t workspace_fact_count;
    const uint8_t *string_bytes;
    size_t string_byte_count;
    omniwm_uuid focused_workspace_id;
    uint32_t interaction_monitor_id;
    uint32_t previous_interaction_monitor_id;
    uint8_t has_focused_workspace_id;
    uint8_t has_interaction_monitor_id;
    uint8_t has_previous_interaction_monitor_id;
} omniwm_restore_topology_input;

typedef struct {
    uint32_t monitor_id;
    omniwm_uuid workspace_id;
} omniwm_restore_visible_assignment;

typedef struct {
    uint32_t source_kind;
    uint32_t source_index;
    omniwm_uuid workspace_id;
} omniwm_restore_disconnected_cache_output_entry;

typedef struct {
    omniwm_restore_visible_assignment *visible_assignments;
    size_t visible_assignment_capacity;
    size_t visible_assignment_count;
    omniwm_restore_disconnected_cache_output_entry *disconnected_cache_entries;
    size_t disconnected_cache_capacity;
    size_t disconnected_cache_count;
    uint32_t interaction_monitor_id;
    uint32_t previous_interaction_monitor_id;
    uint8_t refresh_restore_intents;
    uint8_t has_interaction_monitor_id;
    uint8_t has_previous_interaction_monitor_id;
} omniwm_restore_topology_output;

typedef struct {
    omniwm_restore_string_ref bundle_id;
    omniwm_restore_string_ref role;
    omniwm_restore_string_ref subrole;
    omniwm_restore_string_ref title;
    int32_t window_level;
    uint32_t parent_window_id;
    uint8_t has_bundle_id;
    uint8_t has_role;
    uint8_t has_subrole;
    uint8_t has_title;
    uint8_t has_window_level;
    uint8_t has_parent_window_id;
} omniwm_restore_persisted_key;

typedef struct {
    omniwm_restore_persisted_key key;
    omniwm_uuid workspace_id;
    omniwm_restore_monitor_key preferred_monitor;
    omniwm_rect floating_frame;
    omniwm_point normalized_floating_origin;
    size_t preferred_monitor_name_penalty_offset;
    uint8_t restore_to_floating;
    uint8_t consumed;
    uint8_t has_workspace_id;
    uint8_t has_preferred_monitor;
    uint8_t has_floating_frame;
    uint8_t has_normalized_floating_origin;
} omniwm_restore_persisted_entry_snapshot;

typedef struct {
    omniwm_restore_persisted_key metadata_key;
    uint32_t metadata_mode;
    const omniwm_restore_monitor_context *monitors;
    size_t monitor_count;
    const omniwm_restore_persisted_entry_snapshot *entries;
    size_t entry_count;
    const uint8_t *preferred_monitor_name_penalties;
    size_t preferred_monitor_name_penalty_count;
    const uint8_t *string_bytes;
    size_t string_byte_count;
} omniwm_restore_persisted_hydration_input;

typedef struct {
    uint32_t outcome;
    size_t entry_index;
    omniwm_uuid workspace_id;
    uint32_t preferred_monitor_id;
    uint32_t target_mode;
    omniwm_rect floating_frame;
    uint8_t has_entry_index;
    uint8_t has_preferred_monitor_id;
    uint8_t has_floating_frame;
} omniwm_restore_persisted_hydration_output;

typedef struct {
    omniwm_window_token token;
    omniwm_uuid workspace_id;
    uint32_t target_monitor_id;
    omniwm_rect target_monitor_visible_frame;
    omniwm_rect current_frame;
    omniwm_rect floating_frame;
    omniwm_point normalized_origin;
    uint32_t reference_monitor_id;
    uint8_t has_current_frame;
    uint8_t has_normalized_origin;
    uint8_t has_reference_monitor_id;
    uint8_t is_scratchpad_hidden;
    uint8_t is_workspace_inactive_hidden;
} omniwm_restore_floating_rescue_candidate;

typedef struct {
    size_t candidate_index;
    omniwm_rect target_frame;
} omniwm_restore_floating_rescue_operation;

typedef struct {
    omniwm_restore_floating_rescue_operation *operations;
    size_t operation_capacity;
    size_t operation_count;
} omniwm_restore_floating_rescue_output;

int32_t omniwm_restore_plan_event(
    const omniwm_restore_event_input *input,
    omniwm_restore_event_output *output
);

int32_t omniwm_restore_plan_topology(
    const omniwm_restore_topology_input *input,
    omniwm_restore_topology_output *output
);

int32_t omniwm_restore_plan_persisted_hydration(
    const omniwm_restore_persisted_hydration_input *input,
    omniwm_restore_persisted_hydration_output *output
);

int32_t omniwm_restore_plan_floating_rescue(
    const omniwm_restore_floating_rescue_candidate *candidates,
    size_t candidate_count,
    omniwm_restore_floating_rescue_output *output
);

enum {
    OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_MONITOR_CYCLIC = 0,
    OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_MONITOR_LAST = 1,
    OMNIWM_WORKSPACE_NAV_OPERATION_SWAP_WORKSPACE_WITH_MONITOR = 2,
    OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_EXPLICIT = 3,
    OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_RELATIVE = 4,
    OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_WORKSPACE_ANYWHERE = 5,
    OMNIWM_WORKSPACE_NAV_OPERATION_WORKSPACE_BACK_AND_FORTH = 6,
    OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_ADJACENT = 7,
    OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_EXPLICIT = 8,
    OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_ADJACENT = 9,
    OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_EXPLICIT = 10,
    OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_TO_WORKSPACE_ON_MONITOR = 11,
    OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_HANDLE = 12,
};

enum {
    OMNIWM_WORKSPACE_NAV_OUTCOME_NOOP = 0,
    OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE = 1,
    OMNIWM_WORKSPACE_NAV_OUTCOME_INVALID_TARGET = 2,
    OMNIWM_WORKSPACE_NAV_OUTCOME_BLOCKED = 3,
};

enum {
    OMNIWM_WORKSPACE_NAV_LAYOUT_DEFAULT = 0,
    OMNIWM_WORKSPACE_NAV_LAYOUT_NIRI = 1,
    OMNIWM_WORKSPACE_NAV_LAYOUT_DWINDLE = 2,
};

enum {
    OMNIWM_WORKSPACE_NAV_SUBJECT_NONE = 0,
    OMNIWM_WORKSPACE_NAV_SUBJECT_WINDOW = 1,
    OMNIWM_WORKSPACE_NAV_SUBJECT_COLUMN = 2,
};

enum {
    OMNIWM_WORKSPACE_NAV_FOCUS_NONE = 0,
    OMNIWM_WORKSPACE_NAV_FOCUS_WORKSPACE_HANDOFF = 1,
    OMNIWM_WORKSPACE_NAV_FOCUS_RESOLVE_TARGET_IF_PRESENT = 2,
    OMNIWM_WORKSPACE_NAV_FOCUS_SUBJECT = 3,
    OMNIWM_WORKSPACE_NAV_FOCUS_RECOVER_SOURCE = 4,
    OMNIWM_WORKSPACE_NAV_FOCUS_CLEAR_MANAGED_FOCUS = 5,
};

typedef struct {
    uint32_t operation;
    uint32_t direction;
    omniwm_uuid current_workspace_id;
    omniwm_uuid source_workspace_id;
    omniwm_uuid target_workspace_id;
    uint32_t adjacent_fallback_workspace_number;
    uint32_t current_monitor_id;
    uint32_t previous_monitor_id;
    omniwm_window_token subject_token;
    omniwm_window_token focused_token;
    omniwm_window_token pending_managed_tiled_focus_token;
    omniwm_uuid pending_managed_tiled_focus_workspace_id;
    omniwm_window_token confirmed_tiled_focus_token;
    omniwm_uuid confirmed_tiled_focus_workspace_id;
    omniwm_window_token confirmed_floating_focus_token;
    omniwm_uuid confirmed_floating_focus_workspace_id;
    omniwm_window_token active_column_subject_token;
    omniwm_window_token selected_column_subject_token;
    uint8_t has_current_workspace_id;
    uint8_t has_source_workspace_id;
    uint8_t has_target_workspace_id;
    uint8_t has_adjacent_fallback_workspace_number;
    uint8_t has_current_monitor_id;
    uint8_t has_previous_monitor_id;
    uint8_t has_subject_token;
    uint8_t has_focused_token;
    uint8_t has_pending_managed_tiled_focus_token;
    uint8_t has_pending_managed_tiled_focus_workspace_id;
    uint8_t has_confirmed_tiled_focus_token;
    uint8_t has_confirmed_tiled_focus_workspace_id;
    uint8_t has_confirmed_floating_focus_token;
    uint8_t has_confirmed_floating_focus_workspace_id;
    uint8_t has_active_column_subject_token;
    uint8_t has_selected_column_subject_token;
    uint8_t is_non_managed_focus_active;
    uint8_t is_app_fullscreen_active;
    uint8_t wrap_around;
    uint8_t follow_focus;
} omniwm_workspace_navigation_input;

typedef struct {
    uint32_t monitor_id;
    double frame_min_x;
    double frame_max_y;
    double center_x;
    double center_y;
    omniwm_uuid active_workspace_id;
    omniwm_uuid previous_workspace_id;
    uint8_t has_active_workspace_id;
    uint8_t has_previous_workspace_id;
} omniwm_workspace_navigation_monitor;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    uint32_t layout_kind;
    omniwm_window_token remembered_tiled_focus_token;
    omniwm_window_token first_tiled_focus_token;
    omniwm_window_token remembered_floating_focus_token;
    omniwm_window_token first_floating_focus_token;
    uint8_t has_monitor_id;
    uint8_t has_remembered_tiled_focus_token;
    uint8_t has_first_tiled_focus_token;
    uint8_t has_remembered_floating_focus_token;
    uint8_t has_first_floating_focus_token;
} omniwm_workspace_navigation_workspace;

typedef struct {
    uint32_t outcome;
    uint32_t subject_kind;
    uint32_t focus_action;
    omniwm_uuid source_workspace_id;
    omniwm_uuid target_workspace_id;
    uint32_t target_workspace_materialization_number;
    uint32_t source_monitor_id;
    uint32_t target_monitor_id;
    omniwm_window_token subject_token;
    omniwm_window_token resolved_focus_token;
    omniwm_uuid *save_workspace_ids;
    size_t save_workspace_capacity;
    size_t save_workspace_count;
    omniwm_uuid *affected_workspace_ids;
    size_t affected_workspace_capacity;
    size_t affected_workspace_count;
    uint32_t *affected_monitor_ids;
    size_t affected_monitor_capacity;
    size_t affected_monitor_count;
    uint8_t has_source_workspace_id;
    uint8_t has_target_workspace_id;
    uint8_t has_source_monitor_id;
    uint8_t has_target_monitor_id;
    uint8_t has_subject_token;
    uint8_t has_resolved_focus_token;
    uint8_t should_materialize_target_workspace;
    uint8_t should_activate_target_workspace;
    uint8_t should_set_interaction_monitor;
    uint8_t should_sync_monitors_to_niri;
    uint8_t should_hide_focus_border;
    uint8_t should_commit_workspace_transition;
} omniwm_workspace_navigation_output;

int32_t omniwm_workspace_navigation_plan(
    const omniwm_workspace_navigation_input *input,
    const omniwm_workspace_navigation_monitor *monitors,
    size_t monitor_count,
    const omniwm_workspace_navigation_workspace *workspaces,
    size_t workspace_count,
    omniwm_workspace_navigation_output *output
);

enum {
    OMNIWM_WORKSPACE_SESSION_OPERATION_PROJECT = 0,
    OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_VISIBLE = 1,
    OMNIWM_WORKSPACE_SESSION_OPERATION_ACTIVATE_WORKSPACE = 2,
    OMNIWM_WORKSPACE_SESSION_OPERATION_SET_INTERACTION_MONITOR = 3,
    OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_PREFERRED_FOCUS = 4,
    OMNIWM_WORKSPACE_SESSION_OPERATION_RESOLVE_WORKSPACE_FOCUS = 5,
    OMNIWM_WORKSPACE_SESSION_OPERATION_APPLY_SESSION_PATCH = 6,
    OMNIWM_WORKSPACE_SESSION_OPERATION_RECONCILE_TOPOLOGY = 7,
};

enum {
    OMNIWM_WORKSPACE_SESSION_OUTCOME_NOOP = 0,
    OMNIWM_WORKSPACE_SESSION_OUTCOME_APPLY = 1,
    OMNIWM_WORKSPACE_SESSION_OUTCOME_INVALID_TARGET = 2,
    OMNIWM_WORKSPACE_SESSION_OUTCOME_INVALID_PATCH = 3,
};

enum {
    OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_UNCONFIGURED = 0,
    OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_MAIN = 1,
    OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SECONDARY = 2,
    OMNIWM_WORKSPACE_SESSION_ASSIGNMENT_SPECIFIC_DISPLAY = 3,
};

enum {
    OMNIWM_WORKSPACE_SESSION_VIEWPORT_NONE = 0,
    OMNIWM_WORKSPACE_SESSION_VIEWPORT_STATIC = 1,
    OMNIWM_WORKSPACE_SESSION_VIEWPORT_GESTURE = 2,
    OMNIWM_WORKSPACE_SESSION_VIEWPORT_SPRING = 3,
};

enum {
    OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_NONE = 0,
    OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_APPLY = 1,
    OMNIWM_WORKSPACE_SESSION_PATCH_VIEWPORT_PRESERVE_CURRENT = 2,
};

enum {
    OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_NONE = 0,
    OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_PENDING = 1,
    OMNIWM_WORKSPACE_SESSION_FOCUS_CLEAR_PENDING_AND_CONFIRMED = 2,
};

enum {
    OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_TILING = 0,
    OMNIWM_WORKSPACE_SESSION_WINDOW_MODE_FLOATING = 1,
};

typedef struct {
    uint32_t operation;
    omniwm_uuid workspace_id;
    uint32_t monitor_id;
    omniwm_uuid focused_workspace_id;
    omniwm_uuid pending_tiled_workspace_id;
    omniwm_uuid confirmed_tiled_workspace_id;
    omniwm_uuid confirmed_floating_workspace_id;
    omniwm_window_token pending_tiled_focus_token;
    omniwm_window_token confirmed_tiled_focus_token;
    omniwm_window_token confirmed_floating_focus_token;
    omniwm_window_token remembered_focus_token;
    uint32_t interaction_monitor_id;
    uint32_t previous_interaction_monitor_id;
    uint32_t current_viewport_kind;
    int32_t current_viewport_active_column_index;
    uint32_t patch_viewport_kind;
    int32_t patch_viewport_active_column_index;
    uint8_t has_workspace_id;
    uint8_t has_monitor_id;
    uint8_t has_focused_workspace_id;
    uint8_t has_pending_tiled_workspace_id;
    uint8_t has_confirmed_tiled_workspace_id;
    uint8_t has_confirmed_floating_workspace_id;
    uint8_t has_pending_tiled_focus_token;
    uint8_t has_confirmed_tiled_focus_token;
    uint8_t has_confirmed_floating_focus_token;
    uint8_t has_remembered_focus_token;
    uint8_t has_interaction_monitor_id;
    uint8_t has_previous_interaction_monitor_id;
    uint8_t has_current_viewport_state;
    uint8_t has_patch_viewport_state;
    uint8_t should_update_interaction_monitor;
    uint8_t preserve_previous_interaction_monitor;
} omniwm_workspace_session_input;

typedef struct {
    uint32_t monitor_id;
    double frame_min_x;
    double frame_max_y;
    double frame_width;
    double frame_height;
    double anchor_x;
    double anchor_y;
    omniwm_uuid visible_workspace_id;
    omniwm_uuid previous_visible_workspace_id;
    omniwm_restore_string_ref name;
    uint8_t is_main;
    uint8_t has_visible_workspace_id;
    uint8_t has_previous_visible_workspace_id;
    uint8_t has_name;
} omniwm_workspace_session_monitor;

typedef struct {
    uint32_t monitor_id;
    double frame_min_x;
    double frame_max_y;
    double frame_width;
    double frame_height;
    double anchor_x;
    double anchor_y;
    omniwm_uuid visible_workspace_id;
    omniwm_uuid previous_visible_workspace_id;
    omniwm_restore_string_ref name;
    uint8_t has_visible_workspace_id;
    uint8_t has_previous_visible_workspace_id;
    uint8_t has_name;
} omniwm_workspace_session_previous_monitor;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t display_id;
    double anchor_x;
    double anchor_y;
    double frame_width;
    double frame_height;
    omniwm_restore_string_ref name;
    uint8_t has_name;
} omniwm_workspace_session_disconnected_cache_entry;

typedef struct {
    omniwm_uuid workspace_id;
    omniwm_point assigned_anchor_point;
    uint32_t assignment_kind;
    uint32_t specific_display_id;
    omniwm_restore_string_ref specific_display_name;
    omniwm_window_token remembered_tiled_focus_token;
    omniwm_window_token remembered_floating_focus_token;
    uint8_t has_assigned_anchor_point;
    uint8_t has_specific_display_id;
    uint8_t has_specific_display_name;
    uint8_t has_remembered_tiled_focus_token;
    uint8_t has_remembered_floating_focus_token;
} omniwm_workspace_session_workspace;

typedef struct {
    omniwm_uuid workspace_id;
    omniwm_window_token token;
    uint32_t mode;
    uint32_t order_index;
    uint8_t has_hidden_proportional_position;
    uint8_t hidden_reason_is_workspace_inactive;
} omniwm_workspace_session_window_candidate;

typedef struct {
    uint32_t monitor_id;
    omniwm_uuid visible_workspace_id;
    omniwm_uuid previous_visible_workspace_id;
    omniwm_uuid resolved_active_workspace_id;
    uint8_t has_visible_workspace_id;
    uint8_t has_previous_visible_workspace_id;
    uint8_t has_resolved_active_workspace_id;
} omniwm_workspace_session_monitor_result;

typedef struct {
    omniwm_uuid workspace_id;
    uint32_t projected_monitor_id;
    uint32_t home_monitor_id;
    uint32_t effective_monitor_id;
    uint8_t has_projected_monitor_id;
    uint8_t has_home_monitor_id;
    uint8_t has_effective_monitor_id;
} omniwm_workspace_session_workspace_projection;

typedef struct {
    uint32_t source_kind;
    uint32_t source_index;
    omniwm_uuid workspace_id;
} omniwm_workspace_session_disconnected_cache_result;

typedef struct {
    uint32_t outcome;
    uint32_t patch_viewport_action;
    uint32_t focus_clear_action;
    uint32_t interaction_monitor_id;
    uint32_t previous_interaction_monitor_id;
    omniwm_window_token resolved_focus_token;
    omniwm_workspace_session_monitor_result *monitor_results;
    size_t monitor_result_capacity;
    size_t monitor_result_count;
    omniwm_workspace_session_workspace_projection *workspace_projections;
    size_t workspace_projection_capacity;
    size_t workspace_projection_count;
    omniwm_workspace_session_disconnected_cache_result *disconnected_cache_results;
    size_t disconnected_cache_result_capacity;
    size_t disconnected_cache_result_count;
    uint8_t has_interaction_monitor_id;
    uint8_t has_previous_interaction_monitor_id;
    uint8_t has_resolved_focus_token;
    uint8_t should_remember_focus;
    uint8_t refresh_restore_intents;
} omniwm_workspace_session_output;

int32_t omniwm_workspace_session_plan(
    const omniwm_workspace_session_input *input,
    const omniwm_workspace_session_monitor *monitors,
    size_t monitor_count,
    const omniwm_workspace_session_previous_monitor *previous_monitors,
    size_t previous_monitor_count,
    const omniwm_workspace_session_workspace *workspaces,
    size_t workspace_count,
    const omniwm_workspace_session_window_candidate *window_candidates,
    size_t window_candidate_count,
    const omniwm_workspace_session_disconnected_cache_entry *disconnected_cache_entries,
    size_t disconnected_cache_entry_count,
    const uint8_t *string_bytes,
    size_t string_byte_count,
    omniwm_workspace_session_output *output
);

enum {
    OMNIWM_IPC_BUNDLE_ID_ERROR_NONE = 0,
    OMNIWM_IPC_BUNDLE_ID_ERROR_REQUIRED = 1,
    OMNIWM_IPC_BUNDLE_ID_ERROR_INVALID = 2,
};

enum {
    OMNIWM_IPC_LINE_SCAN_NO_NEWLINE = -1,
    OMNIWM_IPC_LINE_SCAN_OVERFLOW = -2,
    OMNIWM_IPC_LINE_SCAN_INVALID_ARGUMENT = -3,
};

int64_t omniwm_ipc_resolved_socket_path(
    const char *override_path,
    const char *home_path,
    char *output,
    size_t output_capacity
);

int64_t omniwm_ipc_secret_path(
    const char *socket_path,
    char *output,
    size_t output_capacity
);

uint32_t omniwm_ipc_bundle_id_validation_code(const char *bundle_id);

int64_t omniwm_ipc_automation_manifest_json(
    char *output,
    size_t output_capacity
);

int64_t omniwm_workspace_id_normalize(
    const char *candidate,
    char *output,
    size_t output_capacity
);

int64_t omniwm_workspace_id_from_number(
    uint64_t workspace_number,
    char *output,
    size_t output_capacity
);

uint8_t omniwm_workspace_number_from_raw_id(
    const char *raw_id,
    uint64_t *workspace_number
);

int64_t omniwm_ipc_find_newline(
    const uint8_t *bytes,
    size_t byte_count,
    size_t max_line_bytes
);

int32_t omniwm_ipc_socket_connect(const char *path);
int32_t omniwm_ipc_socket_make_listening(const char *path);
int32_t omniwm_ipc_socket_remove_existing_if_needed(const char *path);
int32_t omniwm_ipc_socket_is_active(const char *path);
int32_t omniwm_ipc_socket_configure(int32_t fd, uint8_t non_blocking);
int32_t omniwm_ipc_socket_is_current_user(int32_t fd);
int32_t omniwm_ipc_write_secret_token(const char *socket_path, const char *token);

int64_t omniwm_ipc_read_secret_token_for_socket(
    const char *socket_path,
    char *output,
    size_t output_capacity
);

#ifdef __cplusplus
}
#endif

#endif
