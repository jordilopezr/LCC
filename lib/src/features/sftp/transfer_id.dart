/// Monotonic source of transfer ids shared by every SFTP transfer (the direct
/// single-operation buttons and the transfer queue), so an in-flight transfer's
/// cancel token can never collide with another's.
int _counter = 0;
int nextTransferId() => _counter++;
