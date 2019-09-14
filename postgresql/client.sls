pkg_postgresql_client:
    pkg.installed:
        - name: {{ salt['pillar.get']('postgresql:lookup:pkg_client') }}
