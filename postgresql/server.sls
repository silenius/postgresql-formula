{%- if salt.pillar.get('zfs:fs') %}
include:
  - zfs.fs
{%- endif %}

{% for instance, config in salt.pillar.get('postgresql:instances', {}).items() %}

{{ instance }}_pkg_postgresql_server:
  pkg.installed:
    - name: {{ config.lookup.pkg_server }}

{{ instance }}_postgresql_pg_data:
  file.directory:
    - name: {{ config.lookup.pg_data }}
    - user: {{ config.lookup.user }}
    - group: {{ config.lookup.user }}
    - mode: 700
    - makdedirs: True

{% if config.conf.log_directory is defined %}
{{ instance }}_postgresql_log_directory:
  file.directory:
    - name: {{ config.conf.log_directory }}
    - user: {{ config.lookup.user }}
    - group: {{ config.lookup.user }}
    - mode: 755
{% endif %}

{{ instance }}_postgresql_sysrc_data_dir:
  sysrc.managed:
    - name: postgresql_data
    - value: {{ config.lookup.pg_data }}
    - require:
      - pkg: {{ instance }}_pkg_postgresql_server

{{ instance }}_postgresql_init_db:
  cmd.run:
    - name: service postgresql oneinitdb
    - cwd: /
    - require:
      - sysrc: {{ instance }}_postgresql_sysrc_data_dir
      - pkg: {{ instance }}_pkg_postgresql_server
      - file: {{ instance }}_postgresql_pg_data
    - unless:
      - test -d {{ config.lookup.pg_data | path_join('base') }}

{{ instance }}_postgresql_conf:
  file.append:
    - name: {{ config.lookup.pg_conf_file }}
    - text:
      - include_dir = '{{ config.lookup.pg_confd_dir }}'

{{ instance }}_postgresql_override_conf:
  file.managed:
    - name: {{ config.lookup.pg_confd_dir | path_join('saltstack.conf') }}
    - user: {{ config.lookup.user }}
    - group: {{ config.lookup.user }}
    - makedirs: True
    - mode: 400
    - dir_mode: 700
    - contents: |
      {% for k,v in config.conf.items() %}
        {{ k }} = '{{ v }}'
      {%- endfor %}
        data_directory = '{{ config.lookup.pg_data }}'
        hba_file = '{{ config.lookup.pg_hba_file }}'
        ident_file = '{{ config.lookup.pg_ident_file }}'
    - require:
      - file: {{ instance }}_postgresql_conf

{{ instance }}_postgresql_pghba_conf:
  file.managed:
    - name: {{ config.lookup.pg_hba_file }}
    - user: {{ config.lookup.user }}
    - group: {{ config.lookup.user }}
    - mode: 600
    {%- if config.acls is defined %}
    - source: salt://postgresql/files/pg_hba.conf.jinja
    - template: jinja
    - defaults:
        acls: {{ config.acls|yaml() }}
    {%- endif %}
    - require:
      - file: {{ instance }}_postgresql_override_conf

{{ instance }}_postgresql_service:
  service.running:
    - name: postgresql
    - enable: True
    - watch:
      - file: {{ instance }}_postgresql_override_conf
      - file: {{ instance }}_postgresql_pghba_conf
    - require:
      - sysrc: {{ instance }}_postgresql_sysrc_data_dir

#############
### ROLES ###
#############

{% if config.roles is defined %}
{% for k, v in config.roles.items() %}

{% if k != config.lookup.user %}

{% if v.absent|default(False) %}
{{ instance }}_postgresql_role_{{ k }}:
  postgres_user.absent:
    - name: {{ k }}
    - user: {{ config.lookup.user }}

{% else %}

{{ instance }}_postgresql_role_{{ k }}:
  postgres_user.present:
    - name: {{ k }}
    - login: {{ v.get('login', True) }}
    - createdb: {{ v.get('createdb', False) }}
    - replication: {{ v.get('replication', False) }}
    - user: {{ config.lookup.user }}
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

{% if config.databases is defined %}
{% for k,v in config.databases.items() %}

{% if k != 'postgres' %}

{% if v.absent|default(False) %}
{{ instance }}_postgresql_database_{{ k }}:
  postgres_database.absent:
    - name: {{ k }}
    - user: {{ config.lookup.user }}

{% else %}

{{ instance }}_postgresql_database_{{ k }}:
  postgres_database.present:
    - name: {{ k }}
    - owner: {{ v.owner }}
    - user: {{ config.lookup.user }}
    {% if v.encoding is defined %}
    - encoding: {{ v.encoding }}
    {% endif %}
    {% if v.lc_collate is defined %}
    - lc_collate: {{ v.lc_collate }}
    {% endif %}
    {% if v.lc_ctype is defined %}
    - lc_ctype: {{ v.lc_ctype }}
    {% endif %}
    {% if v.template is defined %}
    - template: {{ v.template }}
    {% endif %}
    - require:
      - {{ instance }}_postgres_user: {{ v.owner }}

{% if v.search_path is defined %}
# XXX: check if this is correct..
{{ instance }}_postgresql_database_{{ k }}_set_search_path:
  cmd.run:
    - name: psql --no-psqlrc --no-align --no-readline -d postgres -c 'ALTER DATABASE "{{ k }}" SET search_path TO {{ v.search_path|join(',') }}'
    - runas: {{ config.lookup.user }}
    - require:
      - {{ instance }}_postgres_database: {{ k }}
{% endif %} 

{% endif %}

{% endif %}

{% if v.pgbouncer|default(True) %}
# Create a dedicated pgbouncer schema to put the dedicated auth_query function
{{ instance }}_postgresql_database_{{ k }}_pgbouncer_schema:
  postgres_schema.present:
    - dbname: {{ k }}
    - name: pgbouncer
    - owner: pgbouncer
    - user: {{ config.lookup.user }}
    - require:
      - {{ instance }}_postgres_user: pgbouncer

# Note: the query is run inside target database, so the dedicated function
# needs to be installed into each database.
# Use a non-admin user (pgbouncer) that calls SECURITY DEFINER function.
{{ instance }}_postgresql_database_{{ k }}_pgbouncer_lookup:
  cmd.script:
    - source: salt://postgresql/files/auth_query.sh
    - runas: {{ config.lookup.user }}
    - env:
      - PSQL_ARGS: --no-psqlrc --no-align --no-readline -d {{ k }}
    - require:
      - {{ instance }}_postgres_schema: postgresql_database_{{ k }}_pgbouncer_schema

{{ instance }}_postgresql_database_{{ k }}_pgbouncer_connect:
  postgres_privileges.present:
    - name: pgbouncer
    - object_type: database
    - object_name: {{ k }}
    - privileges:
      - CONNECT
    - user: {{ config.lookup.user }}

{% endif %}

{% endfor %}
{% endif %}

{% endfor %}
