// Generated from the live BADSQ schema (migrations 0001-0017).
//
// DO NOT EDIT BY HAND except for the noted fix below. Regenerate after every migration:
//   supabase gen types typescript --project-id <ref> > src/types/database.types.ts
// (or, without the CLI, via the Supabase MCP generate_typescript_types tool)
//
// MANUAL FIX: the generator emits `save_item_version`'s Args as
// `p_old_item_id: string`, but the function's actual parameter is nullable
// (NULL means "create a brand-new item"), and Supabase's generator does not
// encode SQL parameter nullability. Left as `string` this makes `createItem()`
// fail to typecheck when it legitimately passes `null`. Corrected to
// `string | null` by hand below; re-check this after every regeneration.

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      audio_recordings: {
        Row: {
          agreement: boolean | null
          deleted_at: string | null
          duration_ms: number | null
          file_size_bytes: number | null
          id: string
          is_reliability_subsample: boolean
          mime_type: string | null
          notes: string | null
          primary_rated_at: string | null
          primary_rater_id: string | null
          primary_rating: boolean | null
          rating_status: string
          response_id: string
          scheduled_deletion_at: string | null
          secondary_rated_at: string | null
          secondary_rater_id: string | null
          secondary_rating: boolean | null
          storage_path: string
          uploaded_at: string
        }
        Insert: {
          agreement?: boolean | null
          deleted_at?: string | null
          duration_ms?: number | null
          file_size_bytes?: number | null
          id?: string
          is_reliability_subsample?: boolean
          mime_type?: string | null
          notes?: string | null
          primary_rated_at?: string | null
          primary_rater_id?: string | null
          primary_rating?: boolean | null
          rating_status?: string
          response_id: string
          scheduled_deletion_at?: string | null
          secondary_rated_at?: string | null
          secondary_rater_id?: string | null
          secondary_rating?: boolean | null
          storage_path: string
          uploaded_at?: string
        }
        Update: {
          agreement?: boolean | null
          deleted_at?: string | null
          duration_ms?: number | null
          file_size_bytes?: number | null
          id?: string
          is_reliability_subsample?: boolean
          mime_type?: string | null
          notes?: string | null
          primary_rated_at?: string | null
          primary_rater_id?: string | null
          primary_rating?: boolean | null
          rating_status?: string
          response_id?: string
          scheduled_deletion_at?: string | null
          secondary_rated_at?: string | null
          secondary_rater_id?: string | null
          secondary_rating?: boolean | null
          storage_path?: string
          uploaded_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "audio_recordings_primary_rater_id_fkey"
            columns: ["primary_rater_id"]
            isOneToOne: false
            referencedRelation: "researchers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audio_recordings_response_id_fkey"
            columns: ["response_id"]
            isOneToOne: true
            referencedRelation: "full_export_v1"
            referencedColumns: ["response_id"]
          },
          {
            foreignKeyName: "audio_recordings_response_id_fkey"
            columns: ["response_id"]
            isOneToOne: true
            referencedRelation: "ml_export_v1"
            referencedColumns: ["response_id"]
          },
          {
            foreignKeyName: "audio_recordings_response_id_fkey"
            columns: ["response_id"]
            isOneToOne: true
            referencedRelation: "responses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audio_recordings_secondary_rater_id_fkey"
            columns: ["secondary_rater_id"]
            isOneToOne: false
            referencedRelation: "researchers"
            referencedColumns: ["id"]
          },
        ]
      }
      consent_records: {
        Row: {
          assigned_code: string | null
          consent_date: string
          consent_given: boolean
          digitized_at: string | null
          digitized_by: string | null
          id: string
          paper_form_scan_ref: string | null
          participant_id: string | null
          q1_doctor_eval: boolean | null
          q1_not_sure: boolean | null
          q1_school_eval: boolean | null
          q2_extra_primary_support: string | null
          q3_family_history: string | null
        }
        Insert: {
          assigned_code?: string | null
          consent_date: string
          consent_given: boolean
          digitized_at?: string | null
          digitized_by?: string | null
          id?: string
          paper_form_scan_ref?: string | null
          participant_id?: string | null
          q1_doctor_eval?: boolean | null
          q1_not_sure?: boolean | null
          q1_school_eval?: boolean | null
          q2_extra_primary_support?: string | null
          q3_family_history?: string | null
        }
        Update: {
          assigned_code?: string | null
          consent_date?: string
          consent_given?: boolean
          digitized_at?: string | null
          digitized_by?: string | null
          id?: string
          paper_form_scan_ref?: string | null
          participant_id?: string | null
          q1_doctor_eval?: boolean | null
          q1_not_sure?: boolean | null
          q1_school_eval?: boolean | null
          q2_extra_primary_support?: string | null
          q3_family_history?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "consent_records_digitized_by_fkey"
            columns: ["digitized_by"]
            isOneToOne: false
            referencedRelation: "researchers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "consent_records_participant_id_fkey"
            columns: ["participant_id"]
            isOneToOne: false
            referencedRelation: "participants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fk_consent_session_code"
            columns: ["assigned_code"]
            isOneToOne: false
            referencedRelation: "sessions"
            referencedColumns: ["assigned_code"]
          },
        ]
      }
      criterion_classification: {
        Row: {
          classification: string | null
          computed_at: string
          item5_score: number | null
          items6_10_sum: number | null
          participant_id: string
          q2_score: number | null
          q3_score: number | null
          rule_version: string
          strong_count: number | null
          weak_count: number | null
        }
        Insert: {
          classification?: string | null
          computed_at?: string
          item5_score?: number | null
          items6_10_sum?: number | null
          participant_id: string
          q2_score?: number | null
          q3_score?: number | null
          rule_version: string
          strong_count?: number | null
          weak_count?: number | null
        }
        Update: {
          classification?: string | null
          computed_at?: string
          item5_score?: number | null
          items6_10_sum?: number | null
          participant_id?: string
          q2_score?: number | null
          q3_score?: number | null
          rule_version?: string
          strong_count?: number | null
          weak_count?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "criterion_classification_participant_id_fkey"
            columns: ["participant_id"]
            isOneToOne: true
            referencedRelation: "participants"
            referencedColumns: ["id"]
          },
        ]
      }
      domain_intros: {
        Row: {
          active: boolean
          created_at: string
          display_order: number
          domain: string
          edited_by: string | null
          id: string
          intro_audio_path: string | null
          intro_text: string
          subdomain: string | null
        }
        Insert: {
          active?: boolean
          created_at?: string
          display_order: number
          domain: string
          edited_by?: string | null
          id?: string
          intro_audio_path?: string | null
          intro_text: string
          subdomain?: string | null
        }
        Update: {
          active?: boolean
          created_at?: string
          display_order?: number
          domain?: string
          edited_by?: string | null
          id?: string
          intro_audio_path?: string | null
          intro_text?: string
          subdomain?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "domain_intros_edited_by_fkey"
            columns: ["edited_by"]
            isOneToOne: false
            referencedRelation: "researchers"
            referencedColumns: ["id"]
          },
        ]
      }
      domain_score_results: {
        Row: {
          computed_at: string
          domain: string
          flagged_deficit: boolean | null
          id: string
          participant_id: string
          raw_score: number | null
          scoring_method_version: string
          session_id: string
          threshold_used: number | null
          z_score: number | null
        }
        Insert: {
          computed_at?: string
          domain: string
          flagged_deficit?: boolean | null
          id?: string
          participant_id: string
          raw_score?: number | null
          scoring_method_version: string
          session_id: string
          threshold_used?: number | null
          z_score?: number | null
        }
        Update: {
          computed_at?: string
          domain?: string
          flagged_deficit?: boolean | null
          id?: string
          participant_id?: string
          raw_score?: number | null
          scoring_method_version?: string
          session_id?: string
          threshold_used?: number | null
          z_score?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "domain_score_results_participant_id_fkey"
            columns: ["participant_id"]
            isOneToOne: false
            referencedRelation: "participants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "domain_score_results_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "full_export_v1"
            referencedColumns: ["session_id"]
          },
          {
            foreignKeyName: "domain_score_results_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      item_options: {
        Row: {
          id: string
          is_correct: boolean
          item_id: string
          option_key: string
          option_text: string
        }
        Insert: {
          id?: string
          is_correct?: boolean
          item_id: string
          option_key: string
          option_text: string
        }
        Update: {
          id?: string
          is_correct?: boolean
          item_id?: string
          option_key?: string
          option_text?: string
        }
        Relationships: [
          {
            foreignKeyName: "item_options_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "item_options_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "public_items"
            referencedColumns: ["id"]
          },
        ]
      }
      items: {
        Row: {
          active: boolean
          correct_answer: string | null
          created_at: string
          display_order: number | null
          domain: string
          edited_by: string | null
          id: string
          instruction_audio_path: string | null
          is_instruction_replayable: boolean
          is_practice: boolean
          is_scored: boolean
          is_stimulus_replayable: boolean | null
          item_code: string
          response_format: string
          scoring_mode: string
          stimulus_audio_path: string | null
          stimulus_text: string | null
          subdomain: string | null
          version: number
        }
        Insert: {
          active?: boolean
          correct_answer?: string | null
          created_at?: string
          display_order?: number | null
          domain: string
          edited_by?: string | null
          id?: string
          instruction_audio_path?: string | null
          is_instruction_replayable?: boolean
          is_practice?: boolean
          is_scored?: boolean
          is_stimulus_replayable?: boolean | null
          item_code: string
          response_format: string
          scoring_mode: string
          stimulus_audio_path?: string | null
          stimulus_text?: string | null
          subdomain?: string | null
          version?: number
        }
        Update: {
          active?: boolean
          correct_answer?: string | null
          created_at?: string
          display_order?: number | null
          domain?: string
          edited_by?: string | null
          id?: string
          instruction_audio_path?: string | null
          is_instruction_replayable?: boolean
          is_practice?: boolean
          is_scored?: boolean
          is_stimulus_replayable?: boolean | null
          item_code?: string
          response_format?: string
          scoring_mode?: string
          stimulus_audio_path?: string | null
          stimulus_text?: string | null
          subdomain?: string | null
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "items_edited_by_fkey"
            columns: ["edited_by"]
            isOneToOne: false
            referencedRelation: "researchers"
            referencedColumns: ["id"]
          },
        ]
      }
      ml_snapshots: {
        Row: {
          anonymized_code: string | null
          class_grade: number | null
          domain: string | null
          id: string
          input_modality: string | null
          is_correct: boolean | null
          item_code: string | null
          replay_count_instruction: number | null
          replay_count_stimulus: number | null
          response_format: string | null
          response_id: string | null
          response_latency_from_first_ms: number | null
          response_latency_from_last_ms: number | null
          scored_by: string | null
          selected_option_key: string | null
          snapshot_label: string | null
          snapshot_taken_at: string
          subdomain: string | null
          submitted_at: string | null
          technical_retry_count: number | null
          typed_value: string | null
        }
        Insert: {
          anonymized_code?: string | null
          class_grade?: number | null
          domain?: string | null
          id?: string
          input_modality?: string | null
          is_correct?: boolean | null
          item_code?: string | null
          replay_count_instruction?: number | null
          replay_count_stimulus?: number | null
          response_format?: string | null
          response_id?: string | null
          response_latency_from_first_ms?: number | null
          response_latency_from_last_ms?: number | null
          scored_by?: string | null
          selected_option_key?: string | null
          snapshot_label?: string | null
          snapshot_taken_at?: string
          subdomain?: string | null
          submitted_at?: string | null
          technical_retry_count?: number | null
          typed_value?: string | null
        }
        Update: {
          anonymized_code?: string | null
          class_grade?: number | null
          domain?: string | null
          id?: string
          input_modality?: string | null
          is_correct?: boolean | null
          item_code?: string | null
          replay_count_instruction?: number | null
          replay_count_stimulus?: number | null
          response_format?: string | null
          response_id?: string | null
          response_latency_from_first_ms?: number | null
          response_latency_from_last_ms?: number | null
          scored_by?: string | null
          selected_option_key?: string | null
          snapshot_label?: string | null
          snapshot_taken_at?: string
          subdomain?: string | null
          submitted_at?: string | null
          technical_retry_count?: number | null
          typed_value?: string | null
        }
        Relationships: []
      }
      participants: {
        Row: {
          age_months: number | null
          age_years: number | null
          anonymized_code: string
          class_grade: number
          created_at: string
          created_by_auth_uid: string | null
          gender: string | null
          home_area: string | null
          id: string
          school_id: string | null
        }
        Insert: {
          age_months?: number | null
          age_years?: number | null
          anonymized_code: string
          class_grade: number
          created_at?: string
          created_by_auth_uid?: string | null
          gender?: string | null
          home_area?: string | null
          id?: string
          school_id?: string | null
        }
        Update: {
          age_months?: number | null
          age_years?: number | null
          anonymized_code?: string
          class_grade?: number
          created_at?: string
          created_by_auth_uid?: string | null
          gender?: string | null
          home_area?: string | null
          id?: string
          school_id?: string | null
        }
        Relationships: []
      }
      researchers: {
        Row: {
          added_at: string
          can_manage_items: boolean
          can_rate: boolean
          email: string
          id: string
          user_id: string | null
        }
        Insert: {
          added_at?: string
          can_manage_items?: boolean
          can_rate?: boolean
          email: string
          id?: string
          user_id?: string | null
        }
        Update: {
          added_at?: string
          can_manage_items?: boolean
          can_rate?: boolean
          email?: string
          id?: string
          user_id?: string | null
        }
        Relationships: []
      }
      responses: {
        Row: {
          attempt_number: number
          id: string
          input_modality: string | null
          is_correct: boolean | null
          is_superseded: boolean
          item_id: string
          raw_client_event_log: Json | null
          replay_count_instruction: number | null
          replay_count_stimulus: number | null
          response_client_ts: number | null
          response_latency_from_first_ms: number | null
          response_latency_from_last_ms: number | null
          scored_by: string | null
          selected_option_key: string | null
          selection_change_count: number
          session_id: string
          stimulus_first_end_client_ts: number | null
          stimulus_last_end_client_ts: number | null
          submitted_at: string
          technical_retry_count: number
          typed_value: string | null
          viewport_height: number | null
          viewport_width: number | null
        }
        Insert: {
          attempt_number?: number
          id?: string
          input_modality?: string | null
          is_correct?: boolean | null
          is_superseded?: boolean
          item_id: string
          raw_client_event_log?: Json | null
          replay_count_instruction?: number | null
          replay_count_stimulus?: number | null
          response_client_ts?: number | null
          response_latency_from_first_ms?: number | null
          response_latency_from_last_ms?: number | null
          scored_by?: string | null
          selected_option_key?: string | null
          selection_change_count?: number
          session_id: string
          stimulus_first_end_client_ts?: number | null
          stimulus_last_end_client_ts?: number | null
          submitted_at?: string
          technical_retry_count?: number
          typed_value?: string | null
          viewport_height?: number | null
          viewport_width?: number | null
        }
        Update: {
          attempt_number?: number
          id?: string
          input_modality?: string | null
          is_correct?: boolean | null
          is_superseded?: boolean
          item_id?: string
          raw_client_event_log?: Json | null
          replay_count_instruction?: number | null
          replay_count_stimulus?: number | null
          response_client_ts?: number | null
          response_latency_from_first_ms?: number | null
          response_latency_from_last_ms?: number | null
          scored_by?: string | null
          selected_option_key?: string | null
          selection_change_count?: number
          session_id?: string
          stimulus_first_end_client_ts?: number | null
          stimulus_last_end_client_ts?: number | null
          submitted_at?: string
          technical_retry_count?: number
          typed_value?: string | null
          viewport_height?: number | null
          viewport_width?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "responses_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "responses_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "public_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "responses_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "full_export_v1"
            referencedColumns: ["session_id"]
          },
          {
            foreignKeyName: "responses_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      sessions: {
        Row: {
          assigned_code: string | null
          auth_uid: string
          ended_at: string | null
          id: string
          participant_id: string | null
          session_part: number
          started_at: string
          status: string
        }
        Insert: {
          assigned_code?: string | null
          auth_uid?: string
          ended_at?: string | null
          id?: string
          participant_id?: string | null
          session_part?: number
          started_at?: string
          status?: string
        }
        Update: {
          assigned_code?: string | null
          auth_uid?: string
          ended_at?: string | null
          id?: string
          participant_id?: string | null
          session_part?: number
          started_at?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "sessions_participant_id_fkey"
            columns: ["participant_id"]
            isOneToOne: false
            referencedRelation: "participants"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      full_export_v1: {
        Row: {
          age_months: number | null
          age_years: number | null
          anonymized_code: string | null
          attempt_number: number | null
          audio_duration_ms: number | null
          audio_marked_correct: boolean | null
          audio_mime_type: string | null
          audio_notes: string | null
          audio_storage_path: string | null
          class_grade: number | null
          domain: string | null
          gender: string | null
          home_area: string | null
          input_modality: string | null
          is_correct: boolean | null
          is_reliability_subsample: boolean | null
          is_superseded: boolean | null
          item_code: string | null
          q1_doctor_eval: boolean | null
          q1_not_sure: boolean | null
          q1_school_eval: boolean | null
          q2_extra_primary_support: string | null
          q3_family_history: string | null
          replay_count_instruction: number | null
          replay_count_stimulus: number | null
          response_client_ts: number | null
          response_format: string | null
          response_id: string | null
          response_latency_from_first_ms: number | null
          response_latency_from_last_ms: number | null
          scored_by: string | null
          scoring_mode: string | null
          selected_option_key: string | null
          selection_change_count: number | null
          session_ended_at: string | null
          session_id: string | null
          session_started_at: string | null
          stimulus_first_end_client_ts: number | null
          stimulus_last_end_client_ts: number | null
          subdomain: string | null
          submitted_at: string | null
          technical_retry_count: number | null
          typed_value: string | null
          viewport_height: number | null
          viewport_width: number | null
        }
        Relationships: []
      }
      ml_export_v1: {
        Row: {
          anonymized_code: string | null
          class_grade: number | null
          domain: string | null
          input_modality: string | null
          is_correct: boolean | null
          item_code: string | null
          replay_count_instruction: number | null
          replay_count_stimulus: number | null
          response_format: string | null
          response_id: string | null
          response_latency_from_first_ms: number | null
          response_latency_from_last_ms: number | null
          scored_by: string | null
          selected_option_key: string | null
          subdomain: string | null
          submitted_at: string | null
          technical_retry_count: number | null
          typed_value: string | null
        }
        Relationships: []
      }
      public_item_options: {
        Row: {
          id: string | null
          item_id: string | null
          option_key: string | null
          option_text: string | null
        }
        Relationships: [
          {
            foreignKeyName: "item_options_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "item_options_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "public_items"
            referencedColumns: ["id"]
          },
        ]
      }
      public_items: {
        Row: {
          display_order: number | null
          domain: string | null
          id: string | null
          instruction_audio_path: string | null
          is_instruction_replayable: boolean | null
          is_practice: boolean | null
          is_scored: boolean | null
          is_stimulus_replayable: boolean | null
          item_code: string | null
          practice_correct_answer: string | null
          response_format: string | null
          stimulus_audio_path: string | null
          stimulus_text: string | null
          subdomain: string | null
          version: number | null
        }
        Insert: {
          display_order?: number | null
          domain?: string | null
          id?: string | null
          instruction_audio_path?: string | null
          is_instruction_replayable?: boolean | null
          is_practice?: boolean | null
          is_scored?: boolean | null
          is_stimulus_replayable?: boolean | null
          item_code?: string | null
          practice_correct_answer?: never
          response_format?: string | null
          stimulus_audio_path?: string | null
          stimulus_text?: string | null
          subdomain?: string | null
          version?: number | null
        }
        Update: {
          display_order?: number | null
          domain?: string | null
          id?: string | null
          instruction_audio_path?: string | null
          is_instruction_replayable?: boolean | null
          is_practice?: boolean | null
          is_scored?: boolean | null
          is_stimulus_replayable?: boolean | null
          item_code?: string | null
          practice_correct_answer?: never
          response_format?: string | null
          stimulus_audio_path?: string | null
          stimulus_text?: string | null
          subdomain?: string | null
          version?: number | null
        }
        Relationships: []
      }
    }
    Functions: {
      can_manage_items: { Args: never; Returns: boolean }
      can_rate: { Args: never; Returns: boolean }
      generate_participant_code: { Args: never; Returns: string }
      is_researcher: { Args: never; Returns: boolean }
      reliability_subsample_rate: { Args: never; Returns: number }
      save_item_version: {
        Args: { p_item: Json; p_old_item_id: string | null; p_options: Json }
        Returns: string
      }
      start_session: {
        Args: never
        Returns: {
          out_assigned_code: string
          out_session_id: string
        }[]
      }
      submit_session: {
        Args: {
          p_consent?: Json
          p_participant: Json
          p_responses: Json
          p_session_id: string
        }
        Returns: string
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
