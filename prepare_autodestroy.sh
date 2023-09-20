#!/bin/bash

# install required dependencies
apt -y install gdisk
apt -y install efibootmgr

WORKDIR="/boot/autodestroy"
mkdir $WORKDIR
rm -rf $WORKDIR/*
cd $WORKDIR

# EXTRACT THE INITIAL RAMDISK
rm ./init
echo "EXTRACTING /boot/initrd.img"
cpio_blocks=$(dd if=/boot/initrd.img skip=0 | cpio -it 2>&1 1>/dev/null | cut -d' ' -f1)

dd if=/boot/initrd.img skip=0 | cpio -di 2>/dev/null
echo "1st chunk extracted:"
ls -l

chunk_2_type=$(dd if=/boot/initrd.img skip=$cpio_blocks | file - | cut -d' ' -f2)
echo "chunk 2 type is: $chunk_2_type"

dd if=/boot/initrd.img skip=$cpio_blocks 2>/dev/null | zstdcat 2>/dev/null | cpio -di 2>/dev/null
echo "2nd chunk extracted:"
ls -l

echo "PLEASE confirm everything is alright and press ENTER to continue, or CTRL-c to abort."
read -n 1 -s


# MODIFY THE RAMDISK 

# copy the executables and their deps over to the initramfs
cp -f $(which dd) usr/bin/
for file in $(ldd usr/bin/dd | cut -d' ' -f3 | grep -vE ^$)
do
	cp $file lib/x86_64-linux-gnu/
done

cp $(which sgdisk) bin/
for file in $(ldd bin/sgdisk | cut -d' ' -f3 | grep -vE ^$)
do
	cp $file lib/x86_64-linux-gnu/
done

cp $(which wipefs) bin/
for file in $(ldd bin/wipefs | cut -d' ' -f3 | grep -vE ^$)
do
	cp $file lib/x86_64-linux-gnu/
done

cp $(which efibootmgr) bin/
for file in $(ldd bin/efibootmgr | cut -d' ' -f3 | grep -vE ^$)
do
	cp $file lib/x86_64-linux-gnu/
done

cp $(which rev) bin/
for file in $(ldd bin/rev | cut -d' ' -f3 | grep -vE ^$)
do
	cp $file lib/x86_64-linux-gnu/
done

DESTROY_BIN="bin/destroy.sh"
echo '#!/bin/sh' > $DESTROY_BIN
echo 'mount -t efivarfs efivarfs /sys/firmware/efi/efivars'  >> $DESTROY_BIN
echo 'for entry in $(efibootmgr | grep Boot0 | grep -v EFI | cut -d* -f1 | cut -dt -f2); do efibootmgr -B -b $entry; done' >> $DESTROY_BIN
echo 'efibootmgr -v' >> $DESTROY_BIN
echo 'export rootfs=$(mount | grep -w "on /root"|cut -d" " -f1)' >> $DESTROY_BIN
echo 'echo ROOTFS IS: $rootfs' >> $DESTROY_BIN
echo 'umount /root' >> $DESTROY_BIN
echo 'sgdisk -Z $rootfs' >> $DESTROY_BIN
echo 'wipefs -af $rootfs' >> $DESTROY_BIN
echo 'echo Erasing drive... please wait...' >> $DESTROY_BIN
echo 'dd if=/dev/zero of=$(echo $rootfs|rev|cut -b2-|rev) bs=4M status=progress' >> $DESTROY_BIN
echo 'echo DESTROYED. Please reboot.' >> $DESTROY_BIN
echo 'reboot' >> $DESTROY_BIN
chmod +x $DESTROY_BIN

# patch the init script
sed -i -r 's/(^# Mount cleanup$)/exec \/bin\/destroy.sh\n\1/' ./init
# sed -i -r 's/(^# Mount cleanup$)/exec \/usr\/bin\/sh\n\1/' ./init


# build the initramfs cpio archive
find . -print0 | cpio --null --create --verbose --format=newc | gzip --best > /boot/destroy.cpio.gz

# ADD A CUSTOM GRUB ENTRY
GRUB_CUSTOM="/etc/grub.d/40_custom"
ROOT_UUID=$(blkid $(mount | grep -w "on /") -s UUID -o value)

echo "" >> $GRUB_CUSTOM
echo "menuentry 'Destroy' --users morro --class os 'destroy' { " >> $GRUB_CUSTOM
echo "        load_video" >> $GRUB_CUSTOM
echo "        set gfxpayload=keep" >> $GRUB_CUSTOM
echo "        insmod gzio" >> $GRUB_CUSTOM
echo "        insmod part_gpt" >> $GRUB_CUSTOM
echo "        insmod ext2" >> $GRUB_CUSTOM
echo "        search --no-floppy --fs-uuid --set=root $ROOT_UUID" >> $GRUB_CUSTOM
echo "        linux /boot/vmlinuz root=UUID=$ROOT_UUID ro" >> $GRUB_CUSTOM
echo "        initrd /boot/destroy.cpio.gz" >> $GRUB_CUSTOM
echo "}" >> $GRUB_CUSTOM

# password protect the destroy menu entry
echo ""
echo "set superusers=\"morro\"" >> $GRUB_CUSTOM
echo "password morro morrolinux.it" >> $GRUB_CUSTOM
echo "export superusers" >> $GRUB_CUSTOM
sed -i -r 's/(.*menuentry )(.*)/\1--unrestricted \2/g' /etc/grub.d/10_linux


# make the menu visible
sed -i 's/GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/g' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/g' /etc/default/grub

# rebuild grub menu
grub-mkconfig -o /boot/grub/grub.cfg

echo "ALL IS DONE! - Now you can reboot.."
