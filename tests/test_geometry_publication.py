import unittest
from unittest.mock import Mock
from rqe.geometry.publication import publish_mesh

class MeshPublicationTests(unittest.TestCase):
    def mesh(self):
        return {'positions':[0,0,0,1,0,0,0,1,0],'indices':[0,1,2],
                'normals':[0,0,1]*3,'uvs':[0,0,1,0,0,1]}
    def test_preserves_seams_and_converts_index_base(self):
        bridge=Mock();bridge.call.return_value={'status':'PUBLISHED','assetId':123}
        result=publish_mesh(bridge,self.mesh(),'Original model')
        args=bridge.call.call_args.args
        self.assertEqual(args[0],'assets.create_mesh')
        self.assertEqual(args[1]['triangles'],[1,2,3])
        self.assertEqual(args[1]['normals'],self.mesh()['normals'])
        self.assertEqual(args[1]['uvs'],self.mesh()['uvs'])
        self.assertEqual(result['assetId'],123)
    def test_invalid_mesh_never_reaches_publication(self):
        for field,value in [('positions',[0,0,float('nan')]*3),('indices',[0,1,3]),('indices',[0,1,.5]),('indices',[]),('normals',[1]),('uvs',[0,0]),('uvs',[0,0,1,0,float('inf'),1])]:
            with self.subTest(field=field,value=value):
                bridge=Mock();data=self.mesh();data[field]=value
                with self.assertRaises(ValueError):publish_mesh(bridge,data,'Invalid')
                bridge.call.assert_not_called()
    def test_transport_uncertainty_is_not_retried(self):
        bridge=Mock();bridge.call.side_effect=TimeoutError('uncertain')
        with self.assertRaises(TimeoutError):publish_mesh(bridge,self.mesh(),'Original')
        bridge.call.assert_called_once()
