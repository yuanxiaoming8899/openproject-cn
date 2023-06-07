#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2023 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

# Will create journals for a journable (e.g. WorkPackage and Meeting)
# As a journal is basically a copy of the current state of the database, consisting of the journable as well as its
# custom values and attachments, those entries are copied in the database.
# Copying and thereby creation only takes place if a change of the current state and the last journal is identified.
# Note, that the adequate creation of a journal which represents the state that is generated by a single user action depends on
# no other user/action altering the current state at the same time especially in a multi process/thread setup.
# Therefore, the whole update of a journable needs to be safeguarded by a mutex. In our implementation, we use
#
# OpenProject::Mutex.with_advisory_lock_transaction(journable)
#
# for this purpose.

# rubocop:disable Rails/SquishedSQLHeredocs
module Journals
  class CreateService
    attr_accessor :journable, :user

    def initialize(journable, user)
      self.user = user
      self.journable = journable
    end

    def call(notes: '', cause: {})
      Journal.transaction do
        journal = create_journal(notes, cause)

        if journal
          reload_journals
          touch_journable(journal)
        end

        ServiceResult.success result: journal
      end
    end

    private

    # If the journalizing happens within the configured aggregation time, is carried out by the same user
    # and only the predecessor or the journal to be created has notes, the changes are aggregated.
    # Instead of removing the predecessor, return it here so that it can be stripped in the journal creating
    # SQL to than be refilled. That way, references to the journal, including ones users have, are kept intact.
    def aggregatable_predecessor(notes, cause)
      predecessor = journable.last_journal

      if aggregatable?(predecessor, notes, cause)
        predecessor
      end
    end

    def create_journal(notes, cause)
      predecessor = aggregatable_predecessor(notes, cause)

      log_journal_creation(predecessor)

      create_sql = create_journal_sql(predecessor, notes, cause)

      # We need to ensure that the result is genuine. Otherwise,
      # calling the service repeatedly for the same journable
      # could e.g. return a (query cached) journal creation
      # that then e.g. leads to the later code thinking that a journal was
      # created.
      result = Journal.connection.uncached do
        ::Journal
          .connection
          .select_one(create_sql)
      end

      Journal.instantiate(result) if result
    end

    # The sql necessary for creating the journal inside the database.
    # It consists of a couple of parts that are kept as individual queries (as CTEs) but
    # are all executed within a single database call.
    #
    # The first three CTEs('cleanup_predecessor_data', 'cleanup_predecessor_attachable' and 'cleanup_predecessor_customizable')
    # strip the information of a predecessor if one exists. If no predecessor exists, a noop SQL statement is employed instead.
    # To strip the information from the journal, the data record (e.g. from work_packages_journals) as well as the
    # attachment and custom value information is removed. The journal itself is kept and will later on have its
    # updated_at and possibly its notes property updated.
    #
    # The next CTEs (`max_journals`) responsibility is to fetch the latests journal and have that available for later queries
    # (i.e. when determining the latest state of the journable and when getting the current version number).
    #
    # The next CTE (`changes`) determines whether a change as occurred so that a new journal needs to be created. The next CTE,
    # that will insert new data, will only do so if the changes CTE returns an entry. The only two exceptions to this check is
    # that if a note is provided or a predecessor is replaced, a journal will be created regardless of whether any changes are
    # detected. To determine whether a change is worthy of being journalized, the current and the latest journalized state are
    # compared in three aspects:
    # * the journable's table columns are compared to the columns in the journable's journal data table
    # (e.g. work_package_journals for WorkPackages). Only columns that exist in the journable's journal data table are considered
    # (and some columns like the primary key `id` is ignored). Therefore, to add an attribute to be journalized, it needs to
    # be added to that table.
    # * the journable's attachments are compared to the attachable_journals entries being associated with the most recent journal.
    # * the journable's custom values are compared to the customizable_journals entries being associated with the most
    # recent journal.
    # When comparing text based values, newlines are normalized as otherwise users having a different OS might change a text value
    # without intending to.
    #
    # Only if a change has been identified (or if a note/predecessor is present) is a journal inserted by the
    # next CTE (`insert_journal`). Its creation timestamp will be the updated_at value of the journable as this is the
    # logical creation time. If a note is present, however, the current time is taken as it signifies an action in itself and
    # there might not be a change at all. In such a case, the journable will later on receive the creation date of the
    # journal as its updated_at value. The update timestamp of a journable and the creation date of its most recent
    # journal should always be in sync. In case a predecessor is aggregated, an update of the already persisted, and
    # stripped of its data, journal is carried out.
    #
    # Both cases (having a note or a change) can at this point be identified by a journal having been created. Therefore, the
    # return value of that insert statement is further on used to identify whether the next statements (`insert_data`,
    # `insert_attachable` and `insert_customizable`) should actually insert data. It is additionally used as the values returned
    # by the overall SQL statement so that an AR instance can be instantiated with it.
    #
    # If a journal is created, all columns that also exist in the journable's data table are inserted as a new entry into
    # to the data table with a reference to the newly created journal. Again, newlines are normalized.
    #
    # If a journal is created, all entries in the attachments table associated to the journable are recreated as entries
    # in the attachable_journals table.
    #
    # If a journal is created, all entries in the custom_values table associated to the journable are recreated as entries
    # in the customizable_journals table. Again, newlines are normalized.
    def create_journal_sql(predecessor, notes, cause)
      <<~SQL
        WITH cleanup_predecessor_data AS (
          #{cleanup_predecessor_data(predecessor)}
        ),
        cleanup_predecessor_attachable AS (
          #{cleanup_predecessor_attachable(predecessor)}
        ),
        cleanup_predecessor_customizable AS (
          #{cleanup_predecessor_customizable(predecessor)}
        ),
        max_journals AS (
          #{select_max_journal_sql(predecessor)}
        ), changes AS (
          #{select_changed_sql}
        ), insert_data AS (
          #{insert_data_sql(predecessor, notes, cause)}
        ), inserted_journal AS (
          #{update_or_insert_journal_sql(predecessor, notes, cause)}
        ), insert_attachable AS (
          #{insert_attachable_sql}
        ), insert_customizable AS (
          #{insert_customizable_sql}
        )

        SELECT * from inserted_journal
      SQL
    end

    def cleanup_predecessor_data(predecessor)
      cleanup_predecessor(predecessor,
                          data_table_name,
                          :id,
                          :data_id)
    end

    def cleanup_predecessor_attachable(predecessor)
      cleanup_predecessor(predecessor,
                          'attachable_journals',
                          :journal_id,
                          :id)
    end

    def cleanup_predecessor_customizable(predecessor)
      cleanup_predecessor(predecessor,
                          'customizable_journals',
                          :journal_id,
                          :id)
    end

    def cleanup_predecessor(predecessor, table_name, column, referenced_id)
      return "SELECT 1" unless predecessor

      sql = <<~SQL
        DELETE
        FROM
         #{table_name}
        WHERE
         #{column} = :#{column}
      SQL

      sanitize sql,
               column => predecessor.send(referenced_id)
    end

    def update_or_insert_journal_sql(predecessor, notes, cause)
      if predecessor
        update_journal_sql(predecessor, notes, cause)
      else
        insert_journal_sql(notes, cause)
      end
    end

    def update_journal_sql(predecessor, notes, cause)
      # If there is a predecessor, we don't want to create a new one, we simply rewrite it.
      # The original data of that predecessor (data e.g. work_package_journals, customizable_journals, attachable_journals)
      # has been deleted before but the notes need to taken over and the timestamps updated as if the
      # journal would have been created.
      #
      # A lot of the data does not need to be set anew, since we only aggregate if that data stays the same
      # (e.g. the user_id).
      journal_sql = <<~SQL
        UPDATE
          journals
        SET
          notes = :notes,
          updated_at = #{timestamp_sql},
          data_id = insert_data.id,
          cause = :cause
        FROM insert_data
        WHERE journals.id = :predecessor_id
        RETURNING
          journals.*
      SQL

      sanitize(journal_sql,
               notes: notes.presence || predecessor.notes,
               predecessor_id: predecessor.id,
               cause: cause_sql(cause))
    end

    def insert_journal_sql(notes, cause)
      journal_sql = <<~SQL
        INSERT INTO
          journals (
            journable_id,
            journable_type,
            version,
            user_id,
            notes,
            created_at,
            updated_at,
            data_id,
            data_type,
            cause
          )
        SELECT
          :journable_id,
          :journable_type,
          COALESCE(max_journals.version, 0) + 1,
          :user_id,
          :notes,
          #{journal_timestamp_sql(notes, ':created_at')},
          #{journal_timestamp_sql(notes, ':updated_at')},
          insert_data.id,
          :data_type,
          :cause
        FROM max_journals, insert_data
        RETURNING *
      SQL

      sanitize(journal_sql,
               notes:,
               cause: cause_sql(cause),
               journable_id: journable.id,
               journable_type:,
               user_id: user.id,
               created_at: journable_timestamp,
               updated_at: journable_timestamp,
               data_type: journable.class.journal_class.name)
    end

    def insert_data_sql(predecessor, notes, cause)
      condition = if notes.blank? && cause.blank? && predecessor.nil?
                    "AND EXISTS (SELECT * FROM changes)"
                  else
                    ""
                  end

      data_sql = <<~SQL
        INSERT INTO
          #{data_table_name} (
            #{data_sink_columns}
          )
        SELECT
          #{data_source_columns}
        FROM #{journable_table_name}
        #{journable_data_sql_addition}
        WHERE
          #{journable_table_name}.id = :journable_id
          #{condition}
        RETURNING *
      SQL

      sanitize(data_sql,
               journable_id: journable.id)
    end

    def journable_class_name
      journable.class.base_class.name
    end

    def insert_attachable_sql
      attachable_sql = <<~SQL
        INSERT INTO
          attachable_journals (
            journal_id,
            attachment_id,
            filename
          )
        SELECT
          #{id_from_inserted_journal_sql},
          attachments.id,
          attachments.file
        FROM attachments
        WHERE
          #{only_if_created_sql}
          AND attachments.container_id = :journable_id
          AND attachments.container_type = :journable_class_name
      SQL

      sanitize(attachable_sql,
               journable_id: journable.id,
               journable_class_name:)
    end

    def insert_customizable_sql
      customizable_sql = <<~SQL
        INSERT INTO
          customizable_journals (
            journal_id,
            custom_field_id,
            value
          )
        SELECT
          #{id_from_inserted_journal_sql},
          custom_values.custom_field_id,
          #{normalize_newlines_sql('custom_values.value')}
        FROM custom_values
        WHERE
          #{only_if_created_sql}
          AND custom_values.customized_id = :journable_id
          AND custom_values.customized_type = :journable_class_name
          AND custom_values.value IS NOT NULL
          AND custom_values.value != ''
      SQL

      sanitize(customizable_sql,
               journable_id: journable.id,
               journable_class_name:)
    end

    def select_max_journal_sql(predecessor)
      sql = <<~SQL
        SELECT
          :journable_id journable_id,
          :journable_type journable_type,
          COALESCE(journals.version, fallback.version) AS version,
          COALESCE(journals.id, 0) id,
          COALESCE(journals.data_id, 0) data_id
        FROM
          journals
        RIGHT OUTER JOIN
          (SELECT 0 AS version) fallback
        ON
           journals.journable_id = :journable_id
           AND journals.journable_type = :journable_type
           AND journals.version IN (#{max_journal_sql(predecessor)})
      SQL

      sanitize(sql,
               journable_id: journable.id,
               journable_type:)
    end

    def select_changed_sql
      <<~SQL
        SELECT
           *
        FROM
          (#{data_changes_sql}) data_changes
        FULL JOIN
          (#{customizable_changes_sql}) customizable_changes
        ON
          customizable_changes.journable_id = data_changes.journable_id
        FULL JOIN
          (#{attachable_changes_sql}) attachable_changes
        ON
          attachable_changes.journable_id = data_changes.journable_id
      SQL
    end

    def attachable_changes_sql
      attachable_changes_sql = <<~SQL
        SELECT
          max_journals.journable_id
        FROM
          max_journals
        LEFT OUTER JOIN
          attachable_journals
        ON
          attachable_journals.journal_id = max_journals.id
        FULL JOIN
          (SELECT *
           FROM attachments
           WHERE attachments.container_id = :journable_id AND attachments.container_type = :container_type) attachments
        ON
          attachments.id = attachable_journals.attachment_id
        WHERE
          (attachments.id IS NULL AND attachable_journals.attachment_id IS NOT NULL)
          OR (attachable_journals.attachment_id IS NULL AND attachments.id IS NOT NULL)
      SQL

      sanitize(attachable_changes_sql,
               journable_id: journable.id,
               container_type: journable_class_name)
    end

    def customizable_changes_sql
      customizable_changes_sql = <<~SQL
        SELECT
          max_journals.journable_id
        FROM
          max_journals
        LEFT OUTER JOIN
          customizable_journals
        ON
          customizable_journals.journal_id = max_journals.id
        FULL JOIN
          (SELECT *
           FROM custom_values
           WHERE custom_values.customized_id = :journable_id AND custom_values.customized_type = :customized_type) custom_values
        ON
          custom_values.custom_field_id = customizable_journals.custom_field_id
        WHERE
          (custom_values.value IS NULL AND customizable_journals.value IS NOT NULL)
          OR (customizable_journals.value IS NULL AND custom_values.value IS NOT NULL AND custom_values.value != '')
          OR (#{normalize_newlines_sql('customizable_journals.value')} !=
              #{normalize_newlines_sql('custom_values.value')})
      SQL

      sanitize(customizable_changes_sql,
               customized_type: journable_class_name,
               journable_id: journable.id)
    end

    def data_changes_sql
      data_changes_sql = <<~SQL
        SELECT
          #{journable_table_name}.id journable_id
        FROM
          (SELECT * FROM #{journable_table_name} #{journable_data_sql_addition}) #{journable_table_name}
        LEFT JOIN
          (SELECT * FROM max_journals
           JOIN
             #{data_table_name}
           ON
             #{data_table_name}.id = max_journals.data_id) #{data_table_name}
        ON
          #{journable_table_name}.id = #{data_table_name}.journable_id
        WHERE
          #{journable_table_name}.id = :journable_id AND (#{data_changes_condition_sql})
      SQL

      sanitize(data_changes_sql,
               journable_id: journable.id)
    end

    def max_journal_sql(predecessor)
      sql = <<~SQL
        SELECT MAX(version)
        FROM journals
        WHERE journable_id = :journable_id
        AND journable_type = :journable_type
      SQL

      if predecessor
        sanitize "#{sql} AND version < :predecessor_version",
                 journable_id: journable.id,
                 journable_type:,
                 predecessor_version: predecessor.version
      else
        sanitize sql,
                 journable_id: journable.id,
                 journable_type:
      end
    end

    def only_if_created_sql
      "EXISTS (SELECT * from inserted_journal)"
    end

    def id_from_inserted_journal_sql
      "(SELECT id FROM inserted_journal)"
    end

    def data_changes_condition_sql
      data_table = data_table_name
      journable_table = journable_table_name

      data_changes = (journable.journaled_columns_names - text_column_names).map do |column_name|
        <<~SQL
          (#{journable_table}.#{column_name} != #{data_table}.#{column_name})
          OR (#{journable_table}.#{column_name} IS NULL AND #{data_table}.#{column_name} IS NOT NULL)
          OR (#{journable_table}.#{column_name} IS NOT NULL AND #{data_table}.#{column_name} IS NULL)
        SQL
      end

      data_changes += text_column_names.map do |column_name|
        <<~SQL
          #{normalize_newlines_sql("#{journable_table}.#{column_name}")} !=
           #{normalize_newlines_sql("#{data_table}.#{column_name}")}
        SQL
      end

      data_changes.join(' OR ')
    end

    def data_sink_columns
      text_columns = text_column_names
      (journable.journaled_columns_names - text_columns + text_columns).join(', ')
    end

    def data_source_columns
      text_columns = text_column_names
      normalized_text_columns = text_columns.map { |column| normalize_newlines_sql(column) }
      (journable.journaled_columns_names - text_columns + normalized_text_columns).join(', ')
    end

    def journable_data_sql_addition
      journable.class.aaj_options[:data_sql]&.call(journable) || ''
    end

    def text_column_names
      journable.class.columns_hash.select { |_, v| v.type == :text }.keys.map(&:to_sym) & journable.journaled_columns_names
    end

    def journable_timestamp
      journable.send(journable.class.aaj_options[:timestamp])
    end

    def journable_type
      journable.class.base_class.name
    end

    def journable_table_name
      journable.class.table_name
    end

    def data_table_name
      journable.class.journal_class.table_name
    end

    def normalize_newlines_sql(column)
      "REGEXP_REPLACE(COALESCE(#{column},''), '\\r\\n', '\n', 'g')"
    end

    def journal_timestamp_sql(notes, attribute)
      if notes.blank? && journable_timestamp
        attribute
      else
        timestamp_sql
      end
    end

    def cause_sql(cause)
      ActiveSupport::JSON.encode(cause || {})
    end

    def timestamp_sql
      # Use the timestamp of the statement, not now() or statement_timestamp
      # as they always return the same value of the start of transaction
      "statement_timestamp() AT TIME ZONE 'utc'"
    end

    # Because we added the journal via bare metal sql, rails does not yet
    # know of the journal. If the journable has the journals loaded already,
    # the caller might expect the journals to also be updated so we do it for him.
    def reload_journals
      journable.journals.reload if journable.journals.loaded?
    end

    def touch_journable(journal)
      return if journal.notes.blank? && journal.cause.blank?

      # Not using touch here on purpose,
      # as to avoid changing lock versions on the journables for this change
      attributes = journable.send(:timestamp_attributes_for_update_in_model)

      timestamps = attributes.index_with { journal.updated_at }
      journable.update_columns(timestamps) if timestamps.any?
    end

    def aggregatable?(predecessor, notes, cause)
      predecessor.present? &&
        aggregation_active? &&
        within_aggregation_time?(predecessor) &&
        same_user?(predecessor) &&
        same_cause?(predecessor, cause) &&
        only_one_note(predecessor, notes)
    end

    def aggregation_active?
      Setting.journal_aggregation_time_minutes.to_i > 0
    end

    def within_aggregation_time?(predecessor)
      predecessor.updated_at >= (Time.zone.now - Setting.journal_aggregation_time_minutes.to_i.minutes)
    end

    def only_one_note(predecessor, notes)
      predecessor.notes.empty? || notes.empty?
    end

    def same_user?(predecessor)
      predecessor.user_id == user.id
    end

    def same_cause?(predecessor, cause)
      predecessor.cause == cause
    end

    def log_journal_creation(predecessor)
      if predecessor
        Rails.logger.debug { "Aggregating journal #{predecessor.id} for #{journable_type} ##{journable.id}" }
      else
        Rails.logger.debug { "Inserting new journal for #{journable_type} ##{journable.id}" }
      end
    end

    delegate :sanitize,
             to: ::OpenProject::SqlSanitization
  end
end
# rubocop:enable Rails/SquishedSQLHeredocs
