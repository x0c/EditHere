"""EditHere development-host receiver CLI."""

__version__ = "0.1.0"

# Present on health + successful Submit meta so thin clients can reject an older
# receiver that still accepts packages without dumping (假成功).
NAMED_EXECUTOR_DUMP = "named-executor-dump"
