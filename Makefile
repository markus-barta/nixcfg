rebuild:
	sudo nixos-rebuild switch

upgrade:
	sudo nixos-rebuild switch --upgrade

rekey-fallback:
	cd ./secrets && agenix -i ~/.ssh/agenix --rekey

rekey:
	cd ./secrets && agenix --rekey

keyscan:
	ssh-keyscan localhost

build-iso:
	nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage -I nixos-config=iso.nix

boot-iso:
	# -enable-kvm
	nix-shell -p qemu --run "qemu-system-x86_64 -m 256 -cdrom result/iso/nixos-*.iso"
