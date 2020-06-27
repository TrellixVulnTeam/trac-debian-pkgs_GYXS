#!/bin/sh
script_file=`readlink -f "$0"`
script_dir=`dirname "$script_file"`
trac_env="$script_dir/env"
trac_user='trac'
gunicorn_num_workers=1
gunicorn_debug=0
gunicorn_opts=''
clear_env="${TRAC_CLEAR_ENV:-0}"

function upgrade() {
    local upgrade_ok=0

    # Only enable addons once
    if [ ! -f "$trac_env/addons_enabled" ]; then
        echo "done" > "$trac_env/addons_enabled"

        # allow anonymous to run admin page
        su -s /bin/sh -c "trac-admin \"$trac_env\" permission add anonymous TRAC_ADMIN" "$trac_user" || upgrade_ok=1

        trac-ini "$trac_env/conf/trac.ini" "components" "announcer.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "customfieldadmin.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "tracworkflowadmin.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "clients.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "HudsonTrac.HudsonTracPlugin.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "timingandestimationplugin.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "advancedworkflow.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "crashdump.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "iniadmin.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "mastertickets.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "tracrpc.*" "enabled"
        trac-ini "$trac_env/conf/trac.ini" "components" "arsoft.trac.plugins.commitupdater.commit_updater.*" "enabled"
    fi

    if [ $upgrade_ok -eq 0 ]; then
        su -s /bin/sh -c "trac-admin \"$trac_env\" upgrade --no-backup" "$trac_user" || upgrade_ok=1
        su -s /bin/sh -c "trac-admin \"$trac_env\" wiki upgrade" "$trac_user" || upgrade_ok=1
    fi

    if [ $upgrade_ok -eq 0 ]; then
        test -d "$trac_env/tmp/deploy" && rm -rf "$trac_env/tmp/deploy"
        su -s /bin/sh -c "trac-admin \"$trac_env\" deploy \"$trac_env/tmp/deploy\"" "$trac_user" || upgrade_ok=1
        if [ -d "$trac_env/tmp/deploy/htdocs" ]; then
            cp -a "$trac_env/tmp/deploy/htdocs"/* "$trac_env/htdocs"
        else
            echo "Deploy of $trac_env failed" 1>&2
        fi
        test -d "$trac_env/tmp/deploy" && rm -rf "$trac_env/tmp/deploy"
    fi

    # Apply the latest configuration from Docker
    trac-ini "$trac_env/conf/trac.ini" "trac" "base_url" "${TRAC_BASE_URL}"
    trac-ini "$trac_env/conf/trac.ini" "project" "name" "${TRAC_PROJECT_NAME}"
    trac-ini "$trac_env/conf/trac.ini" "project" "descr" "${TRAC_PROJECT_DESCRIPTION}"
    trac-ini "$trac_env/conf/trac.ini" "project" "url" "${TRAC_BASE_URL}"
    trac-ini "$trac_env/conf/trac.ini" "project" "url" "${TRAC_PROJECT_ADMIN}"

    if [ $upgrade_ok -eq 0 ]; then
        echo "Upgrade of $trac_env complete"
    else
        echo "Failed to upgrade $trac_env" 1>&2
    fi

    cat << EOF > /bin/run-trac-admin
#!/bin/sh
su -s /bin/sh -c "trac-admin $trac_env \$*" "$trac_user"
EOF
    chmod +x /bin/run-trac-admin
    return $upgrade_ok
}

function initenv() {
    local init_ok=0
    if [ ! -d "$trac_env" ]; then
        mkdir "$trac_env"
    fi
    if [ ! -d "$trac_env" ]; then
        echo "Failed to create directory $trac_env" 1>&2mkdir "$trac_env"
        init_ok=1
    else
        chown "$trac_user:nogroup" -R "$trac_env" || init_ok=1
        su -s /bin/sh -c "trac-admin \"$trac_env\" initenv \"${TRAC_PROJECT_NAME}\" \"${TRAC_DATABASE}\"" "$trac_user" || init_ok=1
    fi

    if [ $init_ok -eq 0 ]; then
        echo "Initialize of $trac_env complete"
    else
        rm -rf "$trac_env"
        echo "Failed to initialize $trac_env" 1>&2
    fi
    return $init_ok
}

if [ $clear_env -ne 0 ]; then
    echo "Clear environment $trac_env"
    find "$trac_env" -delete
fi

if [ ! -f "$trac_env/VERSION" ]; then
    initenv || exit $?
fi

chown "$trac_user:nogroup" -R "$trac_env"
upgrade || exit $?

if [ $gunicorn_debug -ne 0 ]; then
    gunicorn_opts="$gunicorn_opts -R --capture-output --log-level=DEBUG"
fi

exec gunicorn -w${gunicorn_num_workers} $gunicorn_opts -b 0.0.0.0:8000 -n "trac" --user "$trac_user" --group "nogroup" --chdir "$script_dir" trac_wsgi:application
exit $?
