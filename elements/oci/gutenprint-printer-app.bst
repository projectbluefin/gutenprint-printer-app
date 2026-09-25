kind: script

build-depends:
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:bootstrap/bash.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:bootstrap/coreutils.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/oci-builder.bst
  - ghostscript-fsdk.bst:freedesktop-sdk.bst:components/sed.bst
  - filename: printer-app/version.bst
    config:
      location: /metadata
  - filename: printer-app/core-runtime.bst
    config:
      location: /layer

config:
  commands:
    - |
      version="$(cat /metadata/VERSION)"
      gutenprint_ref="$(cat /metadata/GUTENPRINT_REF)"
      install -d /layer/etc
      printf '%s\n' \
        'root:x:0:0:root:/root:/usr/bin/bash' \
        'nonroot:x:65532:65532:Gutenprint Printer Application:/var/lib/gutenprint-printer-app:/usr/sbin/nologin' \
        >> /layer/etc/passwd
      printf '%s\n' \
        'root:x:0:' \
        'nonroot:x:65532:' \
        >> /layer/etc/group
      rm -rf /layer/run/dbus /layer/run/avahi-daemon /layer/run/gutenprint-printer-app
      rm -rf /layer/usr/lib/debug /layer/usr/share/cups/ipptool
      rm -f /layer/usr/bin/cupsd /layer/usr/bin/ippeveprinter
      chmod 0777 /layer/run
      install -d -m 1777 /layer/tmp
      install -d -m 0777 \
        /layer/var/lib/gutenprint-printer-app \
        /layer/var/lib/gutenprint-printer-app/ppd \
        /layer/var/lib/gutenprint-printer-app/spool
      if [ -f /layer/usr/share/dbus-1/system.conf ]; then
        sed -i '/<user>messagebus<\/user>/d; s/<policy user="root">/<policy user="nonroot">/g' /layer/usr/share/dbus-1/system.conf
      fi
      if [ -f /layer/etc/dbus-1/system.d/avahi-dbus.conf ]; then
        sed -i 's/<policy group="netdev">/<policy group="nonroot">/g; s/<policy user="root">/<policy user="nonroot">/g; s/<policy user="avahi">/<policy user="nonroot">/g' /layer/etc/dbus-1/system.d/avahi-dbus.conf
      fi
      cd "%{install-root}"
      build-oci <<EOF
      mode: oci
      gzip: disabled
      images:
        - os: linux
          architecture: "%{go-arch}"
          layer: /layer
          config:
            User: '65532:65532'
            Entrypoint: ['/usr/bin/catatonit', '--', '/usr/bin/bash', '/usr/libexec/gutenprint-printer-app/container-entrypoint']
            Env:
              - 'HOME=/var/lib/gutenprint-printer-app'
              - 'PATH=/usr/bin:/usr/sbin'
            Labels:
              'org.opencontainers.image.title': 'gutenprint-printer-app'
              'org.opencontainers.image.description': 'Gutenprint Printer Application built from freedesktop-sdk'
              'org.opencontainers.image.source': 'https://github.com/projectbluefin/gutenprint-printer-app'
              'org.opencontainers.image.licenses': 'Apache-2.0 AND GPL-2.0-or-later'
              'org.opencontainers.image.version': '${version}'
              'io.projectbluefin.gutenprint.ref': '${gutenprint_ref}'
              'io.projectbluefin.fsdk.version': '26.08rc.1'
              'io.projectbluefin.fsdk.ref': 'e076d4978ee6945763486f6ebd755d189460e4e7'
      EOF
