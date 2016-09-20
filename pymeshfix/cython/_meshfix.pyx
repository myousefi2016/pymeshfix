"""
Python/Cython wrapper for MeshFix by Marco Attene
"""
from libcpp cimport bool
from cpython.string cimport PyString_AsString

import warnings

import numpy as np
cimport numpy as np

import ctypes

# Numpy must be initialized. When using numpy from C or Cython you must
# _always_ do that, or you will have segfaults
np.import_array()

""" Wrapped tetgen class """
cdef extern from "meshfix.h" namespace "T_MESH":
    cdef cppclass Basic_TMesh_wrap:
        # Constructor
        Basic_TMesh_wrap()

        # Inputs     
        int load(const char*)
        int loadArray(int, double*, int, int*)
        
        # MeshFix
        int removeSmallestComponents()
        int boundaries()
        int fillSmallBoundaries(int, bool)
        int meshclean(int, int)
        int save(const char*, bool)

        # Settings
        void SetVerbose(int)
        
        # Outputs
        int ReturnTotalPoints()
        int ReturnTotalFaces()
        void PopArrays(double*, int*)

        # MISC        
        void Join()
        

cdef class PyTMesh:
    """
    Python class to interface with C++ Basic_TMesh object

    MeshFix V2.0 - by Marco Attene
    If MeshFix is used for research purposes, please cite the following paper:

    M. Attene.\n   A lightweight approach to repairing digitized polygon meshes
    The Visual Computer, 2010. (c) Springer.
    
    """
    
    cdef Basic_TMesh_wrap c_tmesh      # hold a C++ instance which we're wrapping
    
    def __cinit__(self, quiet=1):
        """ Create TMesh object """
        self.c_tmesh = Basic_TMesh_wrap()
        
        # Enable/Disable printed progress
        self.c_tmesh.SetVerbose(not quiet)


    def LoadFile(self, filename):
        """
        Loads mesh from file
        
        Currently, the following file formats are supported:
        Open Inventor (IV), VRML 1.0 and 2.0 (WRL), Object File Format (OFF),
        IMATI Ver-Tri (VER, TRI), PLY, OBJ, STL.
        
        The loader automatically reconstructs a manifold triangle connectivity
        """
        
        # Initializes triangulation
        
        cdef char *cstring = PyString_AsString(filename)
        result = self.c_tmesh.load(cstring);
        if result:
            raise IOError('MeshFix is unable to open {:s}'.format(filename))


    def SaveFile(self, filename, back_approx=False):
        """
        Saves cleaned mesh to file
                
        The file format is deduced from one of the following filename
        extensions:
            wrl = vrml 1.0
            iv = OpenInventor
            off = Object file format
            ply = PLY format
            tri = IMATI Ver-Tri
            
        If 'back_approx' is set to True, vertex coordinates are approximated
        to reflect the limited precision of floating point
        representation in ASCII files. This should be used when
        coherence is necessary between in-memory and saved data.
        A non-zero return value is returned if errors occur.
        """
        
        # Convert filename to c string and save
        cdef char *cstring = PyString_AsString(filename)
        result = self.c_tmesh.save(cstring, back_approx)

        if result:
            raise IOError('MeshFix is unable to save mesh to {:s}'.format(filename))


    def LoadArray(self, v, f):
        """
        Loads points from numpy verticies and faces arrays
        The loader automatically reconstructs a manifold triangle connectivity
        """
        if not v.flags['C_CONTIGUOUS']:
            if v.dtype != np.float:
                v = np.ascontiguousarray(v, dtype=np.float)
            else:
                v = np.ascontiguousarray(v)
    
        elif v.dtype != np.float:
            v = v.astype(np.float)
    
        # Ensure inputs are of the right type
        if not f.flags['C_CONTIGUOUS']:
            if f.dtype != ctypes.c_int:
                f = np.ascontiguousarray(f, dtype=ctypes.c_int)
            else:
                f = np.ascontiguousarray(f)
    
        elif f.dtype != ctypes.c_int:
            f = f.astype(ctypes.c_int)
            
        cdef int nv = v.shape[0]
        cdef double [::1] points = v.ravel()
    
        cdef int nt = f.shape[0]
        cdef int [::1] faces = f.ravel()
        
        # Load to C object
        self.c_tmesh.loadArray(nv, &points[0], nt, &faces[0])
        
        
    def MeshClean(self, int max_iters=10, inner_loops=3):
        """
        Iteratively call strongDegeneracyRemoval and strongIntersectionRemoval
        to produce an eventually clean mesh without degeneracies and intersections.
        The two aforementioned methods are called up to max_iter times and
        each of them is called using 'inner_loops' as a parameter.
        Returns true only if the mesh could be completely cleaned.
        """
        
        self.c_tmesh.meshclean(max_iters, inner_loops)


    def Boundaries(self):
        """ Get the number of boundary loops of the triangle mesh """
        return self.c_tmesh.boundaries()
        
        
    def RemoveSmallestComponents(self):
        return self.c_tmesh.removeSmallestComponents()


    def FillSmallBoundaries(self, nbe=0, refine=True):
        """
        Fills all the holes having at least 'nbe' boundary edges. If 'refine'
        is true, adds inner vertices to reproduce the sampling density
        of the surroundings. Returns number of holes patched.
        If 'nbe' is 0 (default), all the holes are patched.
        """
        return self.c_tmesh.fillSmallBoundaries(nbe, refine)


    def ReturnArrays(self):
        """ Returns points array from tmesh object """
        
        # Size point array
        cdef int npoints = self.c_tmesh.ReturnTotalPoints()
        cdef double [::1] points = np.empty(npoints*3)

        # Size face array
        cdef int nfaces = self.c_tmesh.ReturnTotalFaces()
        cdef int [::1] faces = np.empty(nfaces*3, ctypes.c_int)

        # Populate points array
        self.c_tmesh.PopArrays(&points[0], &faces[0])

        v = np.asarray(points).reshape((-1, 3))
        f = np.asarray(faces).reshape((-1, 3))
        
        return v, f
        

    def JoinClosestComponents(self):
        """
        Attempts to join nearby open components.  Should be run before mesh
        repair
        """
        self.c_tmesh.Join()

        
def CleanFromFile(infile, outfile, verbose=True, joincomp=False):
    """ Performs default cleaning procedure on input file """

    # Create mesh object and load from file
    tin = PyTMesh(verbose)
    tin.LoadFile(infile)
    if joincomp:
        tin.JoinClosestComponents()
    
    Repair(tin, verbose, joincomp)
    
    # Save to file
    if verbose:
        print('Saving repaired mesh to {:s}'.format(outfile))
    tin.SaveFile(outfile)
    
    
def CleanFromVF(v, f, verbose=True, joincomp=False):
    """
    Performs default cleaning procedure on vertex and face arrays

    Returns cleaned vertex and face arrays
    
    """

    # Create mesh object and load from file
    tin = PyTMesh(verbose)
    tin.LoadArray(v, f)

    Repair(tin, verbose, joincomp)
        
    # return vertex and face arrays
    return tin.ReturnArrays()
    
    
def Repair(tin, verbose, joincomp):
    """ Performs mesh repair using default cleaning procedure """
    
    # Keep only the largest component (i.e. with most triangles)
    sc = tin.RemoveSmallestComponents();
    if sc and verbose:
        print('Removed {:d} small components'.format(sc))
    
    if tin.Boundaries():
        if verbose:
            print('Patching holes...')
        holespatched = tin.FillSmallBoundaries()
        if verbose:
            print('Patched {:d} holes'.format(holespatched))
    
    # Perform mesh cleaning
    if verbose:
        print('Fixing degeneracies and intersections')
        
    tin.Boundaries()
    result = tin.MeshClean()

    # Check boundaries again
    if tin.Boundaries():
        if verbose:
            print('Patching holes...')
        holespatched = tin.FillSmallBoundaries()
        if verbose:
            print('Patched {:d} holes'.format(holespatched))
    
        if verbose:
            print('Performing final check...')
        result = tin.MeshClean()


    if result:
        warnings.warn('MeshFix could not fix everything')