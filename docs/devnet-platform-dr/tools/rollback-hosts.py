"""usage: rollback-hosts.py <label> <node,node,...|all> [--go]
Replace the root volume of the running instances of a console devnet ($DRILL_NET) with their snapshot <label>
(EC2 replace-root-volume: same instance id and address, the instance reboots). Without --go it only lists."""
import os, sys, time
import boto3
NET = os.environ.get("DRILL_NET") or sys.exit("set DRILL_NET to the devnet's name, for example devnet-drill")
TAG = os.environ.get("DRILL_TAG", "dr")  # prefix of the tags this tool puts on its snapshots
ec2 = boto3.Session(region_name=os.environ.get("AWS_REGION", "us-west-2")).client("ec2")
label, want, go = sys.argv[1], sys.argv[2], "--go" in sys.argv
snaps = {}
for s in ec2.describe_snapshots(OwnerIds=["self"], Filters=[{"Name": "tag:%s:label" % TAG, "Values": [label]}, {"Name": "tag:dashnet:network", "Values": [NET]}])["Snapshots"]:
    t = {x["Key"]: x["Value"] for x in s["Tags"]}
    snaps[t[TAG + ":node"]] = (s["SnapshotId"], t[TAG + ":instance"], s["State"])
nodes = sorted(snaps) if want == "all" else want.split(",")
tasks = {}
for n in nodes:
    snap, iid, state = snaps[n]
    print(time.strftime("%H:%M:%S", time.gmtime()), n, iid, snap, state, flush=True)
    if state != "completed":
        sys.exit("snapshot not completed")
if not go:
    sys.exit(0)
# The console finds a devnet's volumes by tag when it deletes the devnet, and a replacement
# volume starts with no tags: remember each root volume's tags and put them on its replacement.
old_tags = {}
for n in nodes:
    iid = snaps[n][1]
    i = ec2.describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0]
    vol = next(b["Ebs"]["VolumeId"] for b in i["BlockDeviceMappings"] if b["DeviceName"] == i["RootDeviceName"])
    old_tags[n] = [t for t in ec2.describe_volumes(VolumeIds=[vol])["Volumes"][0].get("Tags", []) if not t["Key"].startswith("aws:")]
for n in nodes:
    snap, iid, _ = snaps[n]
    r = ec2.create_replace_root_volume_task(InstanceId=iid, SnapshotId=snap, DeleteReplacedRootVolume=True,
        TagSpecifications=[{"ResourceType": "replace-root-volume-task", "Tags": [{"Key": TAG + ":label", "Value": label}, {"Key": TAG + ":node", "Value": n}]}])
    tasks[n] = r["ReplaceRootVolumeTask"]["ReplaceRootVolumeTaskId"]
    print(time.strftime("%H:%M:%S", time.gmtime()), n, "task", tasks[n], flush=True)
pending = dict(tasks)
while pending:
    time.sleep(10)
    for t in ec2.describe_replace_root_volume_tasks(ReplaceRootVolumeTaskIds=list(pending.values()))["ReplaceRootVolumeTasks"]:
        n = next(k for k, v in pending.items() if v == t["ReplaceRootVolumeTaskId"])
        if t["TaskState"] in ("succeeded", "failed", "failed-detached"):
            i = ec2.describe_instances(InstanceIds=[snaps[n][1]])["Reservations"][0]["Instances"][0]
            vol = next(b["Ebs"]["VolumeId"] for b in i["BlockDeviceMappings"] if b["DeviceName"] == i["RootDeviceName"])
            if t["TaskState"] == "succeeded" and old_tags[n]:
                ec2.create_tags(Resources=[vol], Tags=old_tags[n])
            print(time.strftime("%H:%M:%S", time.gmtime()), n, t["TaskState"], t.get("CompleteTime", ""), "root volume now", vol, "tags copied:", len(old_tags[n]), flush=True)
            del pending[n]
print("done")
