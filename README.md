# antscihub-pi-service-manager

A single meta-service that monitors and maintains other services on a Raspberry Pi fleet.

## Install

From any Pi (via fleet shell or SSH):

```bash
sudo git clone https://github.com/soulsynapse/antscihub-pi-service-manager.git ~/Desktop/2-SERVICE-MANAGER
sudo bash ~/Desktop/2-SERVICE-MANAGER/install.sh
```

During install, module repos listed in `config/modules.conf` are also cloned or updated.

To update

```bash
sudo git -C ~/Desktop/2-SERVICE-MANAGER/ pull --ff-only
sudo bash ~/Desktop/2-SERVICE-MANAGER/install.sh
```


## Agent Instructions for Downstream Services and Repos

