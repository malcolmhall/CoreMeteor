//
//  MHMeteorIncrementalStore.m
//  CoreMeteor
//
//  Created by Malcolm Hall on 26/07/2015.
//  Copyright (c) 2015 Malcolm Hall. All rights reserved.
//

#import "MHMeteorIncrementalStore.h"
#import "MHMeteor.h"
#import "MongoDBPredicateAdaptor.h"
#import "MHMongoCursor.h"
#import "MHMongoCollection.h"

static NSString* const kMeteorDocumentIDKey = @"_id";

@interface MHMeteorIncrementalStore()
@property (retain) NSMutableDictionary* cache;
@property (retain) NSMutableArray* liveQueryHandles;
@property (retain) MHMongoCursor* cursor;
@end
@implementation MHMeteorIncrementalStore{
    MHMeteor* _meteor;
}

+(void)initialize{
    if(self == [MHMeteorIncrementalStore class]){
        [NSPersistentStoreCoordinator registerStoreClass:self forStoreType:self.type];
    }
}

+(NSString*)type{
    return NSStringFromClass(self);
}

-(BOOL)loadMetadata:(NSError **)error{
    NSLog(@"options %@", self.options);
    _meteor = self.options[@"meteor"];
    NSAssert(_meteor, @"meteor must be in the options dictionary");
    self.liveQueryHandles = [NSMutableArray array];
    self.cache = [NSMutableDictionary dictionary];
    return YES;
}

- (id)executeRequest:(NSPersistentStoreRequest *)persistentStoreRequest withContext:(NSManagedObjectContext*)context error:(NSError **)error{
    if(persistentStoreRequest.requestType == NSFetchRequestType)
    {
        NSFetchRequest* fetchRequest = (NSFetchRequest*)persistentStoreRequest;
        
        MHMongoCollection* collection = [_meteor collectionForGlobalID:fetchRequest.entityName];
        if(!collection){
#warning - todo read the collection name out of a custom entity property created in the model editor.
            collection = [_meteor collectionNamed:[fetchRequest.entityName lowercaseString]];
            // at this point we don't know if there was a server collection with same name so we can't error.
        }
        NSDictionary* mongoSelector = nil;
        if(fetchRequest.predicate){
            mongoSelector = [MongoDBPredicateAdaptor queryDictFromPredicate:fetchRequest.predicate orError:error];
            if(!mongoSelector){
                if(error){
                    if (error) {
                        *error = [[NSError alloc] initWithDomain:MHMeteorErrorDomain code:0 userInfo:@{NSLocalizedFailureReasonErrorKey:@"The NSPredicate could not be converted to a Mongo selector"}];
                    }
                    return nil;
                }
            }
        }
        NSDictionary* options = [NSDictionary dictionary];
        
        if(fetchRequest.sortDescriptors.count){
            //todo: make real
            NSMutableArray* fixed = [NSMutableArray array];
            for(NSSortDescriptor* s in fetchRequest.sortDescriptors){
                [fixed addObject:@[s.key , s.ascending ? @"asc" : @"desc"]];
            }
            options = @{@"sort":fixed};
        }
        
        self.cursor = [collection findWithMongoSelector:mongoSelector options:options];
        
        //observe changes before fetching so we don't miss any.
        MHMongoLiveQueryHandle* changedHandle = [_cursor observeChangesDocumentIDChanged:^(NSString *documentID, NSDictionary *fields) {
            NSLog(@"changed %@ %@", documentID, fields);
            //NSLog(@"changed newDocument %@",[ejson invokeMethod:@"stringify" withArguments:@[newDocument]]);
            NSMutableDictionary* cachedDocument = _cache[documentID];
            [cachedDocument addEntriesFromDictionary:fields];
            
            NSManagedObjectID* objectID = [self newObjectIDForEntity:fetchRequest.entity referenceObject:documentID];
            NSManagedObject* obj = [context objectRegisteredForID:objectID];
            
            [obj willAccessValueForKey: nil];
            [context refreshObject:obj mergeChanges: YES];
            
            NSNotification* changeNotification = [NSNotification notificationWithName: NSManagedObjectContextObjectsDidChangeNotification
                                                                          object: context
                                                                        userInfo: @{NSUpdatedObjectsKey : @[obj]}];
            [context mergeChangesFromContextDidSaveNotification: changeNotification];
        }];
        [_liveQueryHandles addObject:changedHandle];

        MHMongoLiveQueryHandle* addedHandle = [_cursor observeDocumentAdded:^(NSDictionary *document) {
            NSLog(@"added %@",document);
            NSManagedObject* obj = [self _newObjectInContext:context forEntity:fetchRequest.entity document:document];
 
            [obj willAccessValueForKey: nil];
            [context refreshObject:obj mergeChanges: YES];
            
            NSNotification* changeNotification = [NSNotification notificationWithName: NSManagedObjectContextObjectsDidChangeNotification
                                                                          object: context
                                                                        userInfo: @{NSInsertedObjectsKey : @[obj]}];
           
            [context mergeChangesFromContextDidSaveNotification: changeNotification];
        }];
        [_liveQueryHandles addObject:addedHandle];
        
        MHMongoLiveQueryHandle* removedHandle = [_cursor observeDocumentRemoved:^(NSDictionary *oldDocument) {
            NSLog(@"removed %@",oldDocument);
            
            NSString* documentID = oldDocument[kMeteorDocumentIDKey];
            NSManagedObjectID* objectID = [self newObjectIDForEntity:fetchRequest.entity referenceObject:documentID];
            NSManagedObject* obj = [context objectRegisteredForID:objectID];
            
            // the object will be nil if we were the one that deleted it and this is just the notification coming back in.
            if(obj){
                [context deleteObject:obj];
                
                NSNotification* changeNotification = [NSNotification notificationWithName: NSManagedObjectContextObjectsDidChangeNotification
                                                                                   object: context
                                                                                 userInfo: @{NSDeletedObjectsKey : @[obj]}];
                
                [context mergeChangesFromContextDidSaveNotification: changeNotification];
            }
        }];
        [_liveQueryHandles addObject:removedHandle];
        
        //fetch the records
        NSArray* documents = [_cursor fetch];
        NSMutableArray* result = [NSMutableArray array];
        
        //convert to Meteor objects
        for(NSDictionary* document in documents){
            NSManagedObject* obj = [self _newObjectInContext:context forEntity:fetchRequest.entity document:document];
            [result addObject:obj];
        }
        return result;
    }
    else if(persistentStoreRequest.requestType == NSSaveRequestType){
        NSSaveChangesRequest* request = (NSSaveChangesRequest*)persistentStoreRequest;
        for (NSManagedObject* object in request.updatedObjects) {
            MHMongoCollection* collection = [_meteor collectionForGlobalID:object.entity.name];
            NSString* documentID = (NSString*)[self referenceObjectForObjectID:object.objectID];
            NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:object.changedValues];
            [self _convertBooleansInDictionary:dict];
            [collection updateDocumentWithID:documentID setFields:dict];
        }
        for(NSManagedObject* object in request.insertedObjects){
            MHMongoCollection* collection = [_meteor collectionForGlobalID:object.entity.name];
            NSString* documentID = (NSString*)[self referenceObjectForObjectID:object.objectID];
            NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:object.changedValues];
            [self _convertBooleansInDictionary:dict];
            dict[kMeteorDocumentIDKey] = documentID;
            [collection insertDocument:dict documentInserted:nil];
        }
        for(NSManagedObject* object in request.deletedObjects){
            MHMongoCollection* collection = [_meteor collectionForGlobalID:object.entity.name];
            NSString* documentID = (NSString*)[self referenceObjectForObjectID:object.objectID];
            [collection removeDocumentWithID:documentID documentRemoved:nil];
        }
        return @[];
    }
    return nil;
}

// fix issue with boolean NSNumbers coming out of NSManagedObjects ending up in javascript as integers.
-(void)_convertBooleansInDictionary:(NSMutableDictionary*)dict{
    for(NSString* key in dict.allKeys){
        id obj = dict[key];
        if([obj isKindOfClass:[NSMutableDictionary class]]){
            [self _convertBooleansInDictionary:obj];
        }
        else if([obj isKindOfClass:[NSNumber class]]){
            NSNumber* num = (NSNumber*)obj;
            if(strcmp([num objCType], "c") == 0) {
                dict[key] = [NSNumber numberWithBool:num.boolValue];
            }
        }
    }
}

-(NSManagedObject*)_newObjectInContext:(NSManagedObjectContext*)context forEntity:(NSEntityDescription*)entity document:(NSDictionary*)document{
    NSString* documentID = document[kMeteorDocumentIDKey];
    NSManagedObjectID* objectID = [self newObjectIDForEntity:entity referenceObject:documentID];
    
    NSMutableDictionary* d = [NSMutableDictionary dictionaryWithDictionary:document];
    [d removeObjectForKey:kMeteorDocumentIDKey];
    _cache[documentID] = d;

    NSManagedObject* obj = [context objectWithID:objectID];

    return obj;
}

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID*)objectID withContext:(NSManagedObjectContext*)context error:(NSError**)error{
    NSLog(@"newValuesForObjectWithID");
    NSString* documentID = (NSString*)[self referenceObjectForObjectID:objectID];
    NSMutableDictionary* doc = (NSMutableDictionary*)_cache[documentID];
    
    NSIncrementalStoreNode* node =
    [[NSIncrementalStoreNode alloc] initWithObjectID:objectID
                                          withValues:doc
                                             version:1];
    
    return node;
}

- (id)newValueForRelationship:(NSRelationshipDescription*)relationship forObjectWithID:(NSManagedObjectID*)objectID withContext:(NSManagedObjectContext *)context error:(NSError **)error{
    //return [_destinationPersistentStore newValueForRelationship:relationship forObjectWithID:objectID withContext:context error:error];
    return nil;
}

- (NSArray*)obtainPermanentIDsForObjects:(NSArray*)array error:(NSError **)error{
    NSMutableArray *permanentIDs = [NSMutableArray arrayWithCapacity:array.count];
    [array enumerateObjectsUsingBlock:^(NSManagedObject* obj, NSUInteger idx, BOOL *stop) {
        
        NSString* documentID = [[obj.objectID.URIRepresentation lastPathComponent] substringFromIndex:1]; // removes the t and we are left with a GUID that makes a great mongo ID.
        NSManagedObjectID* objectID = [self newObjectIDForEntity:obj.entity referenceObject:documentID];
        [permanentIDs addObject:objectID];
    }];
    return permanentIDs;
}

// increment that its being used
- (void)managedObjectContextDidRegisterObjectsWithIDs:(NSArray*)objectIDs{
    //[_destinationPersistentStore managedObjectContextDidRegisterObjectsWithIDs:objectIDs];
}

// decrement that its being used
- (void)managedObjectContextDidUnregisterObjectsWithIDs:(NSArray*)objectIDs{
#warning - todo improve this to work with multiple contexts.
    for(NSManagedObjectID* objectID in objectIDs){
        NSString* documentID = (NSString*)[self referenceObjectForObjectID:objectID];
        [_cache removeObjectForKey:documentID];
    }
}

@end