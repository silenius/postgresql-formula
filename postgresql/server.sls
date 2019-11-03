{%- if salt.pillar.get('zfs:fs') %}
include:
  - zfs.fs
{%- endif %}

{% set pgsql = salt.pillar.get('postgresql') %}

pkg_postgresql_server:
  pkg.installed:
    - name: {{ pgsql.lookup.pkg_server }}

postgresql_pg_data:
  file.directory:
    - name: {{ pgsql.lookup.pg_data }}
    - user: {{ pgsql.lookup.user }}
    - group: {{ pgsql.lookup.user }}
    - mode: 700
    - makdedirs: True

{% if pgsql.conf.log_directory is defined %}
postgresql_log_directory:
  file.directory:
    - name: {{ pgsql.conf.log_directory }}
    - user: {{ pgsql.lookup.user }}
    - group: {{ pgsql.lookup.user }}
    - mode: 755
{% endif %}

postgresql_sysrc_data_dir:
  sysrc.managed:
    - name: postgresql_data
    - value: {{ pgsql.lookup.pg_data }}
    - require:
      - pkg: pkg_postgresql_server

postgresql_init_db:
  cmd.run:
    - name: service postgresql oneinitdb
    - cwd: /
    - require:
      - sysrc: postgresql_sysrc_data_dir
      - pkg: pkg_postgresql_server
      - file: postgresql_pg_data
    - unless:
      - test -d {{ pgsql.lookup.pg_data | path_join('base') }}

postgresql_conf:
  file.append:
    - name: {{ pgsql.lookup.pg_conf_file }}
    - text:
      - include_dir = '{{ pgsql.lookup.pg_confd_dir }}'

postgresql_override_conf:
  file.managed:
    - name: {{ pgsql.lookup.pg_confd_dir | path_join('saltstack.conf') }}
    - user: {{ pgsql.lookup.user }}
    - group: {{ pgsql.lookup.user }}
    - makedirs: True
    - mode: 400
    - contents: |
      {% for k,v in pgsql.conf.items() %}
        {{ k }} = '{{ v }}'
      {%- endfor %}
        data_directory = '{{ pgsql.lookup.pg_data }}'
        hba_file = '{{ pgsql.lookup.pg_hba_file }}'
        ident_file = '{{ pgsql.lookup.pg_ident_file }}'
    - require:
      - file: postgresql_conf

postgresql_pghba_conf:
  file.managed:
    - name: {{ pgsql.lookup.pg_hba_file }}
    - user: {{ pgsql.lookup.user }}
    - group: {{ pgsql.lookup.user }}
    - mode: 600
    {%- if pgsql.acls is defined %}
    - source: salt://postgresql/files/pg_hba.conf.jinja
    - template: jinja
    - defaults:
        acls: {{ pgsql.acls|yaml() }}
    {%- endif %}
    - require:
      - file: postgresql_override_conf

postgresql_service:
  service.running:
    - name: postgresql
    - enable: True
    - watch:
      - file: postgresql_override_conf
      - file: postgresql_pghba_conf
    - require:
      - sysrc: postgresql_sysrc_data_dir

#############
### ROLES ###
#############

{% if pgsql.roles is defined %}
{% for k, v in pgsql.roles.items() %}

{% if k != pgsql.lookup.user %}

{% if v.absent|default(False) %}
postgresql_role_{{ k }}:
  postgres_user.absent:
    - name: {{ k }}
    - user: {{ pgsql.lookup.user }}

{% else %}

postgresql_role_{{ k }}:
  postgres_user.present:
    - name: {{ k }}
    - login: {{ v.get('login', True) }}
    - createdb: {{ v.get('createdb', False) }}
    - user: {{ pgsql.lookup.user }}
    - password: {{ v.get('password') }}
  #- require:
    #- service: postgresql_service
{% endif %}

{% endif %}

{% endfor %}
{% endif %}

#################
### DATABASES ###
#################

{% if pgsql.databases is defined %}
{% for k,v in pgsql.databases.items() %}

{% if k != 'postgres' %}

{% if v.absent|default(False) %}
postgresql_database_{{ k }}:
  postgres_database.absent:
    - name: {{ k }}
    - user: {{ pgsql.lookup.user }}

{% else %}

postgresql_database_{{ k }}:
  postgres_database.present:
    - name: {{ k }}
    - owner: {{ v.owner }}
    - user: {{ pgsql.lookup.user }}
    - require:
      - postgres_user: {{ v.owner }}

{% if v.search_path is defined %}
# XXX: check if this is correct..
postgresql_database_{{ k }}_set_search_path:
  cmd.run:
    - name: psql --no-psqlrc --no-align --no-readline -d postgres -c 'ALTER DATABASE "{{ k }}" SET search_path TO {{ v.search_path|join(',') }}'
    - runas: {{ pgsql.lookup.user }}
    - require:
      - postgres_database: {{ k }}
{% endif %} 

{% endif %}

{% endif %}

# Create a dedicated pgbouncer schema to put the dedicated auth_query function
postgresql_database_{{ k }}_pgbouncer_schema:
  postgres_schema.present:
    - dbname: {{ k }}
    - name: pgbouncer
    - owner: pgbouncer
    - user: {{ pgsql.lookup.user }}
    - require:
      - postgres_user: pgbouncer

# Note: the query is run inside target database, so the dedicated function
# needs to be installed into each database.
# Use a non-admin user (pgbouncer) that calls SECURITY DEFINER function.
postgresql_database_{{ k }}_pgbouncer_lookup:
  cmd.script:
    - source: salt://postgresql/files/auth_query.sh
    - runas: {{ pgsql.lookup.user }}
    - env:
      - PSQL_ARGS: --no-psqlrc --no-align --no-readline -d {{ k }}
    - require:
      - postgres_schema: postgresql_database_{{ k }}_pgbouncer_schema

postgresql_database_{{ k }}_pgbouncer_connect:
  postgres_privileges.present:
    - name: pgbouncer
    - object_type: database
    - object_name: {{ k }}
    - privileges:
      - CONNECT
    - user: {{ pgsql.lookup.user }}

{% endfor %}
{% endif %}
