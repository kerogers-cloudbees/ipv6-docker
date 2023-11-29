GCP IPv6 setup, single VM multiple containers running with docker compose.


Create a network with a subnet-mode of custom.
`gcloud compute networks create <network-name> --subnet-mode=custom`
after this gcloud will give firewall rule recommendations. Accept an http allowed option and port 22 for ssh, we'll fix it for IPv6 later in the console. It will look like:
`gcloud compute firewall-rules create <firewall-name> --network <network-name> --allow tcp:22,tcp:3389,icmp,tcp:80,tcp:447`

Create a subnet to use for the VPC where the VM will be created.
`gcloud compute networks subnets create <subnet-name> --network=<network-name> --range=10.1.0.0/16 --stack-type=IPV4_IPV6 --ipv6-access-type=EXTERNAL --region=us-east1`

Then navigate to https://console.cloud.google.com/net-security/firewall-manager/firewall-policies/list
Find the previously created firewall rule in the list follow the link to it. 
Click Edit. Change the Source Filter drop down from IPv4 Ranges to IPv6 Ranges.
Add an appropriate IPv6 Range below that, `::/0` will allow access from all IPv6 sources.
Add additional TCP ports for the OC and controller(s) to use. I added 8080-8090.
Save your changes.

If http access is desired over both IPv4 and IPv6, make a separate firewall rule to allow the other protocol.

Navigate to https://console.cloud.google.com/compute/instances
Create a new instance. 
In the case I was testing, I used an e2-standard-4 machine type, and gave it 20GB of boot disk space. Changed the boot disk type to ubuntu 20.04. I imagine most any linux would do.
Expand the Network Interfaces section, normally it defaults to "default" change it to the IPv4-IPv6 hybrid network created previously.
Create the instance with the button at the bottom of the screen

Once the instance is started, ssh to it either with web browser or gcloud.
Then update the instance with docker compose and the net-tools.
```
sudo apt-get update
sudo apt-get install \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin \
net-tools 
```

I think the command to flush the IPv4 address and use only IPv6 is `sudo ip -4 address flush <interface>` Check with Konstantine to be more certain. Be aware this seems to break the ssh connection, which makes it impossible to proced. (This my guess as to why GCP only does hybrid networks, the control plane is using IPv4.) I was able to get back in by stopping and restarting the instance in the console. It also re-enabled IPv4.

Then `docker compose up` should start OC, a controller and an agent. It's also starting an nginx proxy/gateway which I don't think is actualy used here. 
The initial passwords for the OC and controller should be available in the logging output of docker compose, or use the docker logs command to retrieve them. The OC should be available at http://\[<IPv6 address\]:8080/cjoc and the controller at http://\[IPv6 Address\]:8081/controller

Agents will need to connect to the controller using port 50001, as the OC reserved port 50000 (shouldn't be running jobs on the OC anyway.)
