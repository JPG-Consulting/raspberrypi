#!/bin/bash

ASTERISK_USERS_CONF_USERBASE=6000
CURRENT_EXTENSION_NUM=${ASTERISK_USERS_CONF_USERBASE}
CONFIGURED_EXTENSIONS=()
ASK_TO_REBOOT=0

calc_wt_size() {
    # NOTE: it's tempting to redirect stderr to /dev/null, so supress error 
    # output from tput. However in this case, tput detects neither stdout or 
    # stderr is a tty and so only gives default 80, 24 values
    WT_HEIGHT=17
    WT_WIDTH=$(tput cols)

    if [ -z "$WT_WIDTH" ] || [ "$WT_WIDTH" -lt 60 ]; then
        WT_WIDTH=80
    fi
    if [ "$WT_WIDTH" -gt 178 ]; then
        WT_WIDTH=120
    fi
    WT_MENU_HEIGHT=$(($WT_HEIGHT-7))
}

do_expand_rootfs() {
    if ! [ -h /dev/root ]; then
        whiptail --msgbox "/dev/root does not exist or is not a symlink. Don't know how to expand" 20 60 2
        return 0
    fi

    ROOT_PART=$(readlink /dev/root)
    PART_NUM=${ROOT_PART#mmcblk0p}
    if [ "$PART_NUM" = "$ROOT_PART" ]; then
        whiptail --msgbox "/dev/root is not an SD card. Don't know how to expand" 20 60 2
        return 0
    fi

    # NOTE: the NOOBS partition layout confuses parted. For now, let's only 
    # agree to work with a sufficiently simple partition layout
    if [ "$PART_NUM" -ne 2 ]; then
        whiptail --msgbox "Your partition layout is not currently supported by this tool. You are probably using NOOBS, in which case your root filesystem is already expanded anyway." 20 60 2
        return 0
    fi

    LAST_PART_NUM=$(parted /dev/mmcblk0 -ms unit s p | tail -n 1 | cut -f 1 -d:)

    if [ "$LAST_PART_NUM" != "$PART_NUM" ]; then
        whiptail --msgbox "/dev/root is not the last partition. Don't know how to expand" 20 60 2
        return 0
    fi

    # Get the starting offset of the root partition
    PART_START=$(parted /dev/mmcblk0 -ms unit s p | grep "^${PART_NUM}" | cut -f 2 -d:)
    [ "$PART_START" ] || return 1
    # Return value will likely be error for fdisk as it fails to reload the
    # partition table because the root fs is mounted
    fdisk /dev/mmcblk0 <<EOF
p
d
$PART_NUM
n
p
$PART_NUM
$PART_START
p
w
EOF
    ASK_TO_REBOOT=1

    # now set up an init.d script
cat <<\EOF > /etc/init.d/resize2fs_once &&
#!/bin/sh
### BEGIN INIT INFO
# Provides:          resize2fs_once
# Required-Start:
# Required-Stop:
# Default-Start: 2 3 4 5 S
# Default-Stop:
# Short-Description: Resize the root filesystem to fill partition
# Description:
### END INIT INFO

. /lib/lsb/init-functions

case "$1" in
    start)
        log_daemon_msg "Starting resize2fs_once" &&
        resize2fs /dev/root &&
        rm /etc/init.d/resize2fs_once &&
        update-rc.d resize2fs_once remove &&
        log_end_msg $?
        ;;
    *)
        echo "Usage: $0 start" >&2
        exit 3
        ;;
esac
EOF
    chmod +x /etc/init.d/resize2fs_once &&
    update-rc.d resize2fs_once defaults &&
    whiptail --msgbox "Root partition has been resized.\nThe filesystem will be enlarged upon the next reboot" 20 60 2
}

do_finish() {
    # Cleanup backups
    [ -d /tmp/asterisk ] && rm -rf /tmp/asterisk

    # Disable setup at boor
    if [ -e /etc/profile.d/setup-asterisk.sh ]; then
        rm -f /etc/profile.d/setup-asterisk.sh
    fi

    if [ $ASK_TO_REBOOT -eq 1 ]; then
        whiptail --yesno "¿Desea reiniciar ahora?" 20 60 2
        if [ $? -eq 0 ]; then # yes
            sync
            reboot
        fi
    fi
    exit 0
}

do_backups() {
    [ ! -f /etc/asterisk/sip.conf.orig ] && cp /etc/asterisk/sip.conf /etc/asterisk/sip.conf.orig
    [ ! -f /etc/asterisk/extensions.conf.orig ] && cp /etc/asterisk/extensions.conf /etc/asterisk/extensions.conf.orig
    [ ! -f /etc/asterisk/users.conf.orig ] && cp /etc/asterisk/users.conf /etc/asterisk/users.conf.orig
    
    [ ! -d /tmp/asterisk ] && mkdir -p /tmp/asterisk
    
    cp /etc/asterisk/sip.conf /tmp/asterisk/sip.conf
    cp /etc/asterisk/extensions.conf /tmp/asterisk/extensions.conf
    cp /etc/asterisk/users.conf /temp/asterisk/users.conf
}

do_restore_backups() {
    cp /tmp/asterisk/sip.conf /etc/asterisk/sip.conf
    cp /tmp/asterisk/extensions.conf /etc/asterisk/extensions.conf
    cp /temp/asterisk/users.conf /etc/asterisk/users.conf
}

do_set_userbase()
{
    local userbase=${ASTERISK_USERS_CONF_USERBASE}
    
    while true; do
        userbaser=$(whiptail --inputbox "Introduzca la primera extensión para los usuarios" 20 60 "${ASTERISK_USERS_CONF_USERBASE}" 3>&1 1>&2 2>&3)
        if [ $? -eq 0 ]; then
            if [[ $userbase =~ ^-?[0-9]+$ ]]; then
                ASTERISK_USERS_CONF_USERBASE=${userbase}
                CURRENT_EXTENSION_NUM=${userbase}
                return 0
            else
                whiptail --msgbox "La extensión debe ser un valor numérico." 20 60 1
            fi
        else
            return 1
        fi
    done
}

do_add_user() {
    local extension_fullname=''
    local extension_email=''
    local extension_password=''
    local extension_cid_number=''

    # 1001 está reservado para el cliente del Comtrend VG-8050 via LAN
    if [ $CURRENT_EXTENSION_NUM -eq 1001 ]; then
        ((CURRENT_EXTENSION_NUM=CURRENT_EXTENSION_NUM+1))
    fi

    extension_cid_number=${CURRENT_EXTENSION_NUM}

    extension_password=$(whiptail --passwordbox "Introduzca la contraseña del usuario" 20 60 "" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        return 1
    fi

    extension_fullname=$(whiptail --inputbox "Introduzca el nombre completo del usuario" 20 60 "" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        extension_fullname=''
    fi
    
    extension_email=$(whiptail --inputbox "Introduzca el correo electrónico del usuario" 20 60 "" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        extension_email=''
    fi
    
    echo ""  >> /etc/asterisk/users.conf
    echo "[${extension_cid_number}]" >> /etc/asterisk/users.conf
    echo "host=dynamic" >> /etc/asterisk/users.conf
    echo "secret=${extension_password}" >> /etc/asterisk/users.conf
    if [ -n "${extension_fullname}" ]; then
        echo "fullname=${extension_fullname}" >> /etc/asterisk/users.conf
    fi
    if [ -n "${extension_email}" ]; then
        echo "email=${extension_email}" >> /etc/asterisk/users.conf
    fi
    echo "cid_number=${extension_cid_number}" >> /etc/asterisk/users.conf
    
    CONFIGURED_EXTENSIONS+=( "SIP/${CURRENT_EXTENSION_NUM}" )
    ((CURRENT_EXTENSION_NUM=CURRENT_EXTENSION_NUM+1))
}

do_movistar_ftth() {
    local sip_extensions=$( IFS=$'&'; echo "${CONFIGURED_EXTENSIONS[*]}" )
    
    PHONENUMBER=$(whiptail --inputbox "Introduzca su número de teléfono" 20 60 "$CURRENT_HOSTNAME" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Configuracion para Movistar por SIP
    echo "" >> /etc/asterisk/sip.conf
    echo "[Movistar](!)" >> /etc/asterisk/sip.conf
    echo "type=peer" >> /etc/asterisk/sip.conf
    #echo "callerid=${PHONENUMBER}" >> /etc/asterisk/sip.conf
    #echo "host=telefonica.net" >> /etc/asterisk/sip.conf
    #echo "port=5060" >> /etc/asterisk/sip.conf
    #echo "from-domain=telefonica.net" >> /etc/asterisk/sip.conf
    #echo "fromuser=${PHONENUMBER}" >> /etc/asterisk/sip.conf
    echo "secret=${PHONENUMBER}" >> /etc/asterisk/sip.conf
    echo "dtmfmode=auto" >> /etc/asterisk/sip.conf
    echo "insecure=port,invite" >> /etc/asterisk/sip.conf
    echo "outboundproxy=10.31.255.134:5070" >> /etc/asterisk/sip.conf
    echo "nat=force_rport,comedia" >> /etc/asterisk/sip.conf
    #echo "trustrpid=yes" >> /etc/asterisk/sip.conf
    #echo "sendrpid=yes" >> /etc/asterisk/sip.conf
    echo "disallow=all" >> /etc/asterisk/sip.conf
    echo "allow=ulaw" >> /etc/asterisk/sip.conf
    echo "allow=alaw" >> /etc/asterisk/sip.conf
    #echo "context=from-movistar" >> /etc/asterisk/sip.conf
    
    echo "" >> /etc/asterisk/sip.conf
    echo "[MovistarOut](Movistar)" >> /etc/asterisk/sip.conf
    echo "host=telefonica.net" >> /etc/asterisk/sip.conf
    echo "from-domain=telefonica.net" >> /etc/asterisk/sip.conf
    echo "fromuser=${PHONENUMBER}" >> /etc/asterisk/sip.conf
    
    echo "" >> /etc/asterisk/sip.conf
    echo "[MovistarIn](Movistar)" >> /etc/asterisk/sip.conf
    echo "context=from-movistar" >> /etc/asterisk/sip.conf
    echo "defaultuser=${PHONENUMBER}" >> /etc/asterisk/sip.conf
    echo "host=10.31.255.134" >> /etc/asterisk/sip.conf
    echo "port=5060" >> /etc/asterisk/sip.conf
    echo "qualify=no" >> /etc/asterisk/sip.conf
    echo "trustpid=yes" >> /etc/asterisk/sip.conf
    
    sed -e "s|^;register => 2345:password@sip_proxy/1234|;register => 2345:password@sip_proxy/1234\nregister => ${PHONENUMBER}@telefonica.net:${PHONENUMBER}@10.31.255.134:5070|" -i /etc/asterisk/sip.conf

    echo "" >> /etc/asterisk/extensions.conf
    echo "[outbound-movistar]" >> /etc/asterisk/extensions.conf
    echo "exten => _X.,1,Dial(SIP/MovistarOut/\${EXTEN})" >> /etc/asterisk/extensions.conf
    
    echo "" >> /etc/asterisk/extensions.conf
    echo "[from-movistar]" >> /etc/asterisk/extensions.conf
    echo "exten => s,1,Dial(${sip_extensions})" >> /etc/asterisk/extensions.conf
    
    sed -e "s|^include => demo|include => outbound-movistar|" -i /etc/asterisk/extensions.conf
}

#do_movistar_ftth_comtrend() {
    # Se registra y le puedo llamar pero el no puede llamar :(
    # [1001]
    # type=friend                     ; Friends place calls and receive calls
    # authuser=${PHONENUMBER}
    # defaultuser=authuser=${PHONENUMBER}
    # fromuser=${PHONENUMBER}
    # host=dynamic                    ; This peer register with us
    # dtmfmode=inband                 ; Choices are inband, rfc2833, or info
    # qualify=yes
    # insecure=port,invite
    # disallow=all
    # allow=ulaw
    # allow=alow
    # allow=gsm
    # regexten=${PHONENUMBER}
    # subscribecontext=public
#}

do_chan_dongle() {
    sed -e "s|^exten=+1234567890|exten=${MOBILE_PHONE}|" -i /etc/asterisk/dongle.conf
    sed -e "s|^context=default|context=from-dongle|" -i /etc/asterisk/dongle.conf

    echo "" >> /etc/asterisk/extensions.conf
    echo "[from-dongle]" >> /etc/asterisk/extensions.conf

    # SMS
    echo "exten => sms,1,Verbose(Incoming SMS from \${CALLERID(num)} \${BASE64_DECODE(\${SMS_BASE64})})" >> /etc/asterisk/extensions.conf

    if [ -z "$DONGLE_EMAIL_ADDRESS" ]; then
        echo "exten => sms,n,Set(FILE($DONGLE_SMS_FILE,,,a)=\${STRFTIME(\${EPOCH},,%Y-%m-%d %H:%M:%S)} - \${DONGLENAME} - \${CALLERID(num)}: \${BASE64_DECODE(\${SMS_BASE64})})" >> /etc/asterisk/extensions.conf
        echo "exten => sms,n,System(echo >> $DONGLE_SMS_FILE)" >> /etc/asterisk/extensions.conf
    else
        echo "exten => sms,n,System(echo \"To: $DONGLE_EMAIL_ADDRESS\nSubject: Incoming SMS from \${CALLERID(num)}\n\n\${STRFTIME(\${EPOCH},,%Y-%m-%d %H:%M:%S)} - \${DONGLENAME} - \${CALLERID(num)}: \" > /tmp/sms.txt)" >> /etc/asterisk/extensions.conf
        echo "exten => sms,n,Set(FILE(/tmp/sms.txt,,,a)=\${BASE64_DECODE(\${SMS_BASE64})})" >> /etc/asterisk/extensions.conf
        echo "exten => sms,n,System(sendmail -t < /tmp/sms.txt)" >> /etc/asterisk/extensions.conf
    fi

    if [ -n "$DONGLE_FORWARD_SMS_TO" ]; then
        echo "exten => sms,n,DongleSendSMS(dongle0,$DONGLE_FORWARD_SMS_TO,\${BASE64_DECODE(\${SMS_BASE64})} - from \${CALLERID(num)})" >> /etc/asterisk/extensions.conf
    fi

    echo "exten => sms,n,Hangup()" >> /etc/asterisk/extensions.conf

    # DISA
    if [ -n $DONGLE_DISA_NUM ]; then
        echo "exten => ${DONGLE_DISA_NUM},1,Answer()" >> /etc/asterisk/extensions.conf
        echo "exten => ${DONGLE_DISA_NUM},n,DISA(${DONGLE_DISA_PIN})" >> /etc/asterisk/extensions.conf
    fi

    # All other incoming calls
    echo "exten => _X.,1,Set(CALLERID(name)=\${CALLERID(num)})" >> /etc/asterisk/extensions.conf
    echo "exten => _X.,1,GoTo(from-trunk,\${EXTEN},1)" >> /etc/asterisk/extensions.conf
}

if [ $(id -u) -ne 0 ]; then
    sudo /etc/profile.d/setup-asterisk.sh
    exit 0
fi

calc_wt_size

do_expand_rootfs

do_set_userbase

while true; do
    do_add_user

    whiptail --yesno "¿Desea agregar otro usuario?" 20 60 2 --yes-button Si --no-button No
    if [ $? -eq 1 ]; then
        break
    fi
done

do_movistar_ftth

whiptail --yesno "¿Desea activar chan_dongle?" 20 60 2 --yes-button Si --no-button No
if [ $? -eq 0 ]; then
    do_chan_dongle
fi

do_finish