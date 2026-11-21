"""usage: snapshots.py create <label> | status <label> | delete <label>
EBS snapshots of every root volume of a console devnet ($DRILL_NET). Pause the miner and flush every Core first: see ../README.md."""
import os, sys, time
import boto3
NET = os.environ.get("DRILL_NET") or sys.exit("set DRILL_NET to the devnet's name, for example devnet-drill")
TAG = os.environ.get("DRILL_TAG", "dr")  # prefix of the tags this tool puts on its snapshots
ec2 = boto3.Session(region_name=os.environ.get("AWS_REGION", "us-west-2")).client("ec2")
cmd, label = sys.argv[1], sys.argv[2]
flt = [{"Name": "tag:%s:label" % TAG, "Values": [label]}, {"Name": "tag:dashnet:network", "Values": [NET]}]
if cmd == "create":
    inst = [i for r in ec2.describe_instances(Filters=[{"Name": "tag:dashnet:network", "Values": [NET]}, {"Name": "instance-state-name", "Values": ["running"]}])["Reservations"] for i in r["Instances"]]
    print(time.strftime("%H:%M:%S", time.gmtime()), "start", len(inst), "instances")
    for i in sorted(inst, key=lambda i: next(t["Value"] for t in i["Tags"] if t["Key"] == "dashnet:node")):
        node = next(t["Value"] for t in i["Tags"] if t["Key"] == "dashnet:node")
        vol = next(b["Ebs"]["VolumeId"] for b in i["BlockDeviceMappings"] if b["DeviceName"] == i["RootDeviceName"])
        s = ec2.create_snapshot(VolumeId=vol, Description="DR snapshot %s %s %s" % (label, NET, node), TagSpecifications=[{"ResourceType": "snapshot", "Tags": [
            {"Key": "Name", "Value": "%s-%s-%s" % (TAG, label, node)}, {"Key": TAG + ":label", "Value": label}, {"Key": TAG + ":node", "Value": node},
            {"Key": TAG + ":instance", "Value": i["InstanceId"]}, {"Key": "dashnet:network", "Value": NET}]}])
        print(time.strftime("%H:%M:%S", time.gmtime()), node, i["InstanceId"], vol, s["SnapshotId"], s["StartTime"].strftime("%H:%M:%S.%f")[:-3])
elif cmd == "status":
    for s in sorted(ec2.describe_snapshots(OwnerIds=["self"], Filters=flt)["Snapshots"], key=lambda s: s["Description"]):
        t = {x["Key"]: x["Value"] for x in s["Tags"]}
        print(t[TAG + ":node"], s["SnapshotId"], s["State"], s["Progress"], s["StartTime"].strftime("%H:%M:%S"))
elif cmd == "delete":
    for s in ec2.describe_snapshots(OwnerIds=["self"], Filters=flt)["Snapshots"]:
        ec2.delete_snapshot(SnapshotId=s["SnapshotId"]); print("deleted", s["SnapshotId"])
