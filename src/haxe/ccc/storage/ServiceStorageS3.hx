package ccc.storage;

/**
 CORS configuration:

<?xml version="1.0" encoding="UTF-8"?>
<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <CORSRule>
        <AllowedOrigin>*</AllowedOrigin>
        <AllowedMethod>GET</AllowedMethod>
        <AllowedMethod>PUT</AllowedMethod>
        <AllowedMethod>POST</AllowedMethod>
        <AllowedMethod>DELETE</AllowedMethod>
        <AllowedMethod>HEAD</AllowedMethod>
        <AllowedHeader>*</AllowedHeader>
    </CORSRule>
</CORSConfiguration>

Bucket policy (where <USER> is the id of the user account, and
<BUCKET_NAME> is the name of the S3 bucket:

{
	"Version": "2008-10-17",
	"Statement": [
		{
			"Sid": "",
			"Effect": "Allow",
			"Principal": {
				"AWS": "arn:aws:iam::763896067184:user/<USER>"
			},
			"Action": [
				"s3:ListBucket",
				"s3:GetBucketLocation"
			],
			"Resource": "arn:aws:s3:::<BUCKET_NAME>"
		},
		{
			"Sid": "",
			"Effect": "Allow",
			"Principal": {
				"AWS": "arn:aws:iam::763896067184:user/<USER>"
			},
			"Action": [
				"s3:PutObject",
				"s3:GetObject",
				"s3:DeleteObject",
				"s3:DeleteObjectVersion",
				"s3:RestoreObject",
				"s3:GetObjectVersion"
			],
			"Resource": "arn:aws:s3:::<BUCKET_NAME>/*"
		},
		{
			"Sid": "",
			"Effect": "Allow",
			"Principal": "*",
			"Action": "s3:GetObject",
			"Resource": "arn:aws:s3:::<BUCKET_NAME>/*"
		}
	]
}
 */

import ccc.compute.Definitions;
import ccc.storage.ServiceStorage;
import ccc.storage.*;

import js.node.stream.Readable;
import js.node.stream.Writable;
import js.node.Fs;
import js.npm.aws.AWS;

import promhx.Promise;
import promhx.PromiseTools;
import promhx.StreamPromises;
import promhx.deferred.DeferredPromise;

using Lambda;
using StringTools;

class ServiceStorageS3 extends ServiceStorageBase
{
	var _containerName :String = "bionano-platform-test"; // we always need a bucket
	var _httpAccessUrl :String;
	var _S3 :AWSS3;
	var _initialized :Promise<Bool>;


	private static var precedingSlash = ~/^\/+/;
	private static var endingSlash = ~/\/+$/;
	private static var extraSlash = ~/\/{2,}/g;
	private static var splitRegEx = ~/\/+/g;
	private static var replaceChar :String = "--";

	public function new()
	{
		super();
	}

	override public function toString()
	{
		return '[StorageS3 _rootPath=$_rootPath container=${_containerName} _httpAccessUrl=${_httpAccessUrl}]';
	}

	function initialized() :Promise<Bool>
	{
		if (_initialized == null) {
			var promise = new DeferredPromise();
			_initialized = promise.boundPromise;
			_S3.getBucketPolicy({Bucket:_containerName}, function(err, data) {
				if (err != null) {
					//For now, throw an error and crash. S3 buckets need to be
					//set up manually for now
					promise.boundPromise.reject(err);
					//No bucket exists, let's create one
					// var createBucketOptions = {
					// 	Bucket: _containerName,
					// 	ACL: 'public-read',
					// 	CreateBucketConfiguration: {
					// 		LocationConstraint: _config.credentials.region,
					// 	},
					// 	GrantFullControl: 'FULL_CONTROL'
					// }
					// _S3.createBucket(createBucketOptions, function(err, result) {
					// 	if (err != null) {
					// 		promise.boundPromise.reject(err);
					// 	} else {
					// 		promise.resolve(true);
					// 	}
					// });
				} else {
					promise.resolve(true);
				}
			});
		}
		return _initialized;
	}

	function getClient() :AWSS3
	{
		return _S3;
	}

	public function getContainerName(?options: Dynamic) :String
	{
		return _containerName;
	}

	override public function setConfig(config :StorageDefinition) :ServiceStorageBase
	{
		Assert.notNull(config.container);
		Assert.notNull(config.httpAccessUrl);
		Assert.notNull(config.credentials);

		if (config.container != null) {
			_containerName = config.container;
		}

		var awsConfig = {
			accessKeyId: config.credentials.accessKeyId != null ? config.credentials.accessKeyId : config.credentials.keyId,
			secretAccessKey: config.credentials.secretAccessKey != null ? config.credentials.secretAccessKey : config.credentials.key,
			region: config.credentials.region
		}

		Assert.notNull(awsConfig.region);
		Assert.notNull(awsConfig.accessKeyId);
		Assert.notNull(awsConfig.secretAccessKey);

		_httpAccessUrl = ensureEndsWithSlash(config.httpAccessUrl);
		_S3 = new AWSS3(awsConfig);

		return super.setConfig(config);
	}

	override public function clone() :ServiceStorage
	{
		var copy = new ServiceStorageS3();
		var config = Reflect.copy(_config);
		config.httpAccessUrl = _httpAccessUrl;
		config.container = _containerName;
		config.rootPath = _rootPath;
		// copy._S3 = _S3;
		// copy._initialized = _initialized;
		// copy._httpAccessUrl = _httpAccessUrl;
		// copy._containerName = _containerName;
		copy.setConfig(config);
		return copy;
	}

	override public function exists(path :String) :Promise<Bool>
	{
		path = getPath(path);
		return initialized()
			.pipe(function(_) {
				var promise = new DeferredPromise();
				var params = {Bucket: _containerName, Key: path};
				_S3.headObject(params, function(err, data) {
					if (err != null && Reflect.field(err, 'code') == 'NotFound') {
						promise.resolve(false);
					} else if (err != null) {
						promise.boundPromise.reject(err);
					} else {
						promise.resolve(true);
					}
				});
				return promise.boundPromise;
			});
	}

	override public function readFile(path :String) :Promise<IReadable>
	{
		return exists(path)
			.pipe(function(file_exists) {
				if (file_exists) {
					path = getPath(path);
					var promise = new DeferredPromise();
					var params = {Bucket: _containerName, Key: path};
					promise.resolve(_S3.getObject(params).createReadStream());
					return promise.boundPromise;
				} else {
					return PromiseTools.error('Does not exist: $path');
				}
			});
	}

	override public function readDir(?path :String) :Promise<IReadable>
	{
		throw 'readDir(...) Not implemented';
		return null;
	}

	override public function writeFile(path :String, data :IReadable) :Promise<Bool>
	{
		Assert.notNull(data);
		path = getPath(path);
		var tempFileName :String = null;
		return initialized()
			.pipe(function(_) {
				if (Reflect.hasField(data, 'read')) {
					return Promise.promise(data);
				} else {
					tempFileName = '/tmp/tmpfile${Std.int(Math.random() * 100000)}';
					return StreamPromises.pipe(data, Fs.createWriteStream(tempFileName), [WritableEvent.Finish], 'ServiceStorageS3.writeFile')
						.then(function(done) {
							return cast Fs.createReadStream(tempFileName);
						});
				}
			})
			.pipe(function(stream) {
				var promise = new DeferredPromise();
				var params = {Bucket: _containerName, Key: path, Body: stream};
				var eventDispatcher = _S3.upload(params, function(err, result) {
					if (err != null) {
						promise.boundPromise.reject(err);
					} else {
						promise.resolve(true);
					}
				});
				return promise.boundPromise;
				// This can be integrated later
				// eventDispatcher.on('httpUploadProgress', function(evt) {
				// 	trace('Progress:', evt.loaded, '/', evt.total);
				// });
			})
			.errorPipe(function(err) {
				if (tempFileName != null) {
					Fs.unlink(tempFileName, function(err) {});
				}
				return PromiseTools.error(err);
			});
	}

	override public function copyFile(source :String, target :String) :Promise<Bool>
	{
		Assert.notNull(source);
		Assert.notNull(target);

		return Promise.promise(true)
			.pipe(function (_) {
				return this.readFile(source);
			})
			.pipe(function(readStream) {
				return this.writeFile(target, readStream);
			});
	}

	override public function deleteFile(path :String) :Promise<Bool>
	{
		path = getPath(path);
		return initialized()
			.pipe(function(_) {
				var promise = new DeferredPromise();
				var params = {Bucket: _containerName, Key: path};
				_S3.deleteObject(params, function(err, result) {
					if (err != null) {
						promise.boundPromise.reject(err);
					} else {
						promise.resolve(true);
					}
				});
				return promise.boundPromise;
			});
	}

	override public function deleteDir(?path :String) :Promise<Bool>
	{
		return listDirS3(path)
			.pipe(function(fileList) {
				if (fileList.length > 0) {
					var promise = new DeferredPromise();
					var params = {Bucket: _containerName,
						Delete: {
							Objects:fileList.map(function(f) {
								return {
									Key:f
								}
							})
						}
					};
					_S3.deleteObjects(params, function(err, result) {
						if (err != null) {
							promise.boundPromise.reject(err);
						} else {
							promise.resolve(true);
						}
					});
					return promise.boundPromise;
				} else {
					return Promise.promise(true);
				}
			});
	}

	override public function listDir(?path :String) :Promise<Array<String>>
	{
		path = getPath(path);
		return listDirS3(path)
			.then(function(files) {
				return files.map(function(f) {
					f = path != null ? f.substr(path.length) : f;
					if (f.startsWith('/')) {
						f = f.substr(1);
					}
					return f;
				});
			});
	}

	function listDirS3(?path :String) :Promise<Array<String>>
	{
		return initialized()
			.pipe(function(_) {
				var promise = new DeferredPromise();
				var params = {Bucket: _containerName, Prefix: path, ContinuationToken:null};
				var continuationToken :String = null;

				var fileList = [];

				var getNext = null;
				getNext = function() {
					_S3.listObjectsV2(params, function(err, result) {
						if (err != null) {
							promise.boundPromise.reject(err);
						} else {
							var arr :Array<{Key:String}> = result.Contents;
							for (f in arr) {
								fileList.push(f.Key);
							}
							if (result.NextContinuationToken != null && result.IsTruncated) {
								params.ContinuationToken = result.NextContinuationToken;
								getNext();
							} else {
								promise.resolve(fileList);
							}
						}
					});
				}
				getNext();
				return promise.boundPromise;
			});
	}

	override public function makeDir(?path :String) :Promise<Bool>
	{
		// AWS doesn't require explit creation of directories as it just stores directories in object names
		return Promise.promise(true);
	}

	override public function setRootPath(path :String) :ServiceStorage
	{
		super.setRootPath(path);
		_rootPath = removePrecedingSlash(_rootPath);
		return this;
	}

	override public function appendToRootPath(path :String) :ServiceStorage
	{
		var copy = clone();
		path = path.replace('//', '/');
		copy.setRootPath(getPath(path));
		return copy;
	}

	override public function getPath(p :String) :String
	{
		if (p != null && _httpAccessUrl != null && p.startsWith(_httpAccessUrl)) {
			p = p.substr(_httpAccessUrl.length);
		}
		var path = super.getPath(p);
		return removePrecedingSlash(path);
// 		// AWS S3 allows path-like object names so this functionality isn't necessary
// 		// convert a path to a container replacing / with -
//		result = splitRegEx.replace(result, replaceChar);
// 		return result;
	}

	override public function getExternalUrl(?path :String) :String
	{
		path = getPath(path);
		if (_httpAccessUrl != null) {
			return _httpAccessUrl + path;
		} else {
			return path;
		}
	}

	static function isBucket(s3 :AWSS3, bucket :String) :Promise<Bool>
	{
		var promise = new DeferredPromise();


		return promise.boundPromise;
	}

	static function removePrecedingSlash(s :String) :String
	{
		if (s.startsWith('/')) {
			return removePrecedingSlash(s.substring(1));
		} else {
			return s;
		}
	}
}